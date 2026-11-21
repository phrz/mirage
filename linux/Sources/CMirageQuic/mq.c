// See mq.h. msquic calls back on its own worker threads; every callback here goes straight to Swift.
#include "mq.h"

#include <arpa/inet.h>
#include <msquic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const QUIC_API_TABLE *MsQuic;
static HQUIC Registration;
static HQUIC Configuration;
static const mq_callbacks *CB;
static void *HostCtx;

typedef struct send_block {
    QUIC_BUFFER buf;
    void *send_ctx;
    uint8_t data[];
} send_block;

static void logf_(const char *fmt, unsigned long status) {
    if (!CB || !CB->log) return;
    char line[256];
    snprintf(line, sizeof line, fmt, status);
    CB->log(HostCtx, line);
}

static QUIC_STATUS QUIC_API stream_cb(HQUIC stream, void *ctx, QUIC_STREAM_EVENT *ev) {
    switch (ev->Type) {
    case QUIC_STREAM_EVENT_RECEIVE:
        for (uint32_t i = 0; i < ev->RECEIVE.BufferCount; i++) {
            const QUIC_BUFFER *b = &ev->RECEIVE.Buffers[i];
            if (b->Length) CB->stream_data(ctx, b->Buffer, b->Length);
        }
        if (ev->RECEIVE.Flags & QUIC_RECEIVE_FLAG_FIN) CB->stream_fin(ctx);
        break;
    case QUIC_STREAM_EVENT_SEND_COMPLETE: {
        send_block *blk = (send_block *)ev->SEND_COMPLETE.ClientContext;
        if (blk) {
            CB->send_done(blk->send_ctx, ev->SEND_COMPLETE.Canceled ? 1 : 0);
            free(blk);
        }
        break;
    }
    case QUIC_STREAM_EVENT_PEER_SEND_SHUTDOWN:
    case QUIC_STREAM_EVENT_PEER_SEND_ABORTED:
        CB->stream_fin(ctx);
        break;
    case QUIC_STREAM_EVENT_PEER_RECEIVE_ABORTED:
        MsQuic->StreamShutdown(stream, QUIC_STREAM_SHUTDOWN_FLAG_ABORT, 0);
        break;
    case QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE:
        CB->stream_closed(ctx);
        if (!ev->SHUTDOWN_COMPLETE.AppCloseInProgress) MsQuic->StreamClose(stream);
        break;
    default:
        break;
    }
    return QUIC_STATUS_SUCCESS;
}

static QUIC_STATUS QUIC_API conn_cb(HQUIC conn, void *ctx, QUIC_CONNECTION_EVENT *ev) {
    switch (ev->Type) {
    case QUIC_CONNECTION_EVENT_CONNECTED:
        CB->conn_ready(ctx);
        break;
    case QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_TRANSPORT:
        logf_("QUIC connection shut down by transport: status 0x%lx", (unsigned long)ev->SHUTDOWN_INITIATED_BY_TRANSPORT.Status);
        break;
    case QUIC_CONNECTION_EVENT_PEER_STREAM_STARTED: {
        HQUIC s = ev->PEER_STREAM_STARTED.Stream;
        void *sctx = CB->stream_open(ctx, s);
        MsQuic->SetCallbackHandler(s, (void *)stream_cb, sctx);
        break;
    }
    case QUIC_CONNECTION_EVENT_DATAGRAM_STATE_CHANGED:
        CB->datagram_state(ctx, ev->DATAGRAM_STATE_CHANGED.SendEnabled ? 1 : 0, ev->DATAGRAM_STATE_CHANGED.MaxSendLength);
        break;
    case QUIC_CONNECTION_EVENT_DATAGRAM_RECEIVED:
        CB->datagram(ctx, ev->DATAGRAM_RECEIVED.Buffer->Buffer, ev->DATAGRAM_RECEIVED.Buffer->Length);
        break;
    case QUIC_CONNECTION_EVENT_DATAGRAM_SEND_STATE_CHANGED:
        if (QUIC_DATAGRAM_SEND_STATE_IS_FINAL(ev->DATAGRAM_SEND_STATE_CHANGED.State)) free(ev->DATAGRAM_SEND_STATE_CHANGED.ClientContext);
        break;
    case QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE:
        CB->conn_closed(ctx, ev->SHUTDOWN_COMPLETE.PeerAcknowledgedShutdown ? "closed" : "ended");
        if (!ev->SHUTDOWN_COMPLETE.AppCloseInProgress) MsQuic->ConnectionClose(conn);
        break;
    default:
        break;
    }
    return QUIC_STATUS_SUCCESS;
}

static QUIC_STATUS QUIC_API listener_cb(HQUIC listener, void *ctx, QUIC_LISTENER_EVENT *ev) {
    (void)listener; (void)ctx;
    if (ev->Type != QUIC_LISTENER_EVENT_NEW_CONNECTION) return QUIC_STATUS_SUCCESS;
    char remote[INET6_ADDRSTRLEN + 8] = "?";
    const QUIC_ADDR *a = ev->NEW_CONNECTION.Info->RemoteAddress;
    if (a) {
        char ip[INET6_ADDRSTRLEN] = "";
        if (a->Ip.sa_family == AF_INET) {
            inet_ntop(AF_INET, &a->Ipv4.sin_addr, ip, sizeof ip);
            snprintf(remote, sizeof remote, "%s:%u", ip, ntohs(a->Ipv4.sin_port));
        } else if (a->Ip.sa_family == AF_INET6) {
            inet_ntop(AF_INET6, &a->Ipv6.sin6_addr, ip, sizeof ip);
            snprintf(remote, sizeof remote, "[%s]:%u", ip, ntohs(a->Ipv6.sin6_port));
        }
    }
    HQUIC c = ev->NEW_CONNECTION.Connection;
    void *cctx = CB->conn_open(HostCtx, c, remote);
    MsQuic->SetCallbackHandler(c, (void *)conn_cb, cctx);
    return MsQuic->ConnectionSetConfiguration(c, Configuration);
}

int mq_host_start(uint16_t port, const char *cert_file, const char *key_file, const char *alpn, uint32_t idle_ms,
                  const mq_callbacks *cb, void *host_ctx, char *err, size_t err_len) {
    CB = cb; HostCtx = host_ctx;
    QUIC_STATUS st;
    if (QUIC_FAILED(st = MsQuicOpen2(&MsQuic))) { snprintf(err, err_len, "MsQuicOpen2 failed: 0x%x", st); return -1; }
    QUIC_REGISTRATION_CONFIG reg = { "mirage-host", QUIC_EXECUTION_PROFILE_LOW_LATENCY };
    if (QUIC_FAILED(st = MsQuic->RegistrationOpen(&reg, &Registration))) { snprintf(err, err_len, "RegistrationOpen failed: 0x%x", st); return -1; }

    QUIC_BUFFER alpnBuf = { (uint32_t)strlen(alpn), (uint8_t *)alpn };
    QUIC_SETTINGS s;
    memset(&s, 0, sizeof s);
    s.IdleTimeoutMs = idle_ms; s.IsSet.IdleTimeoutMs = 1;
    s.PeerBidiStreamCount = 64; s.IsSet.PeerBidiStreamCount = 1;
    s.DatagramReceiveEnabled = 1; s.IsSet.DatagramReceiveEnabled = 1;
    s.ServerResumptionLevel = QUIC_SERVER_NO_RESUME; s.IsSet.ServerResumptionLevel = 1;
    // A keyframe is a burst of a few hundred datagrams: start with a wider window than QUIC's default 10 packets.
    s.InitialWindowPackets = 128; s.IsSet.InitialWindowPackets = 1;
    if (QUIC_FAILED(st = MsQuic->ConfigurationOpen(Registration, &alpnBuf, 1, &s, sizeof s, NULL, &Configuration))) {
        snprintf(err, err_len, "ConfigurationOpen failed: 0x%x", st); return -1;
    }
    QUIC_CERTIFICATE_FILE files = { key_file, cert_file };
    QUIC_CREDENTIAL_CONFIG cred;
    memset(&cred, 0, sizeof cred);
    cred.Type = QUIC_CREDENTIAL_TYPE_CERTIFICATE_FILE;
    cred.Flags = QUIC_CREDENTIAL_FLAG_NONE;
    cred.CertificateFile = &files;
    if (QUIC_FAILED(st = MsQuic->ConfigurationLoadCredential(Configuration, &cred))) {
        snprintf(err, err_len, "loading the TLS certificate failed: 0x%x", st); return -1;
    }
    HQUIC listener;
    if (QUIC_FAILED(st = MsQuic->ListenerOpen(Registration, listener_cb, NULL, &listener))) {
        snprintf(err, err_len, "ListenerOpen failed: 0x%x", st); return -1;
    }
    QUIC_ADDR addr;
    memset(&addr, 0, sizeof addr);
    QuicAddrSetFamily(&addr, QUIC_ADDRESS_FAMILY_UNSPEC);
    QuicAddrSetPort(&addr, port);
    if (QUIC_FAILED(st = MsQuic->ListenerStart(listener, &alpnBuf, 1, &addr))) {
        snprintf(err, err_len, "cannot listen on UDP port %u: 0x%x", port, st); return -1;
    }
    return 0;
}

int mq_stream_send(void *stream, const uint8_t *data, uint32_t len, void *send_ctx) {
    send_block *blk = malloc(sizeof(send_block) + len);
    if (!blk) return -1;
    memcpy(blk->data, data, len);
    blk->buf.Length = len; blk->buf.Buffer = blk->data; blk->send_ctx = send_ctx;
    if (QUIC_FAILED(MsQuic->StreamSend((HQUIC)stream, &blk->buf, 1, QUIC_SEND_FLAG_NONE, blk))) { free(blk); return -1; }
    return 0;
}

int mq_datagram_send(void *conn, const uint8_t *data, uint32_t len) {
    send_block *blk = malloc(sizeof(send_block) + len);
    if (!blk) return -1;
    memcpy(blk->data, data, len);
    blk->buf.Length = len; blk->buf.Buffer = blk->data; blk->send_ctx = NULL;
    if (QUIC_FAILED(MsQuic->DatagramSend((HQUIC)conn, &blk->buf, 1, QUIC_SEND_FLAG_NONE, blk))) { free(blk); return -1; }
    return 0;
}

void mq_stream_abort(void *stream) {
    MsQuic->StreamShutdown((HQUIC)stream, QUIC_STREAM_SHUTDOWN_FLAG_ABORT | QUIC_STREAM_SHUTDOWN_FLAG_IMMEDIATE, 0);
}

void mq_conn_shutdown(void *conn) { MsQuic->ConnectionShutdown((HQUIC)conn, QUIC_CONNECTION_SHUTDOWN_FLAG_NONE, 0); }
