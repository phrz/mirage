// A thin server-side layer over msquic for the Linux host: one listener, connections with bidirectional streams and
// the DATAGRAM flow, every buffer copied in and out so Swift never holds msquic memory. Handles are opaque pointers.
#ifndef MIRAGE_MQ_H
#define MIRAGE_MQ_H

#include <stddef.h>
#include <stdint.h>

typedef struct mq_callbacks {
    /// A new connection (handshake not yet done). Returns the context later callbacks for it receive.
    void *(*conn_open)(void *host_ctx, void *conn, const char *remote);
    void (*conn_ready)(void *conn_ctx);
    /// The connection is gone: after this its handle must not be used. Called once, last.
    void (*conn_closed)(void *conn_ctx, const char *why);
    /// A stream the peer opened. Returns the context later callbacks for it receive.
    void *(*stream_open)(void *conn_ctx, void *stream);
    void (*stream_data)(void *stream_ctx, const uint8_t *data, uint32_t len);
    /// The peer finished or aborted sending.
    void (*stream_fin)(void *stream_ctx);
    /// The stream is gone: after this its handle must not be used. Called once, last.
    void (*stream_closed)(void *stream_ctx);
    /// A stream send finished (`send_ctx` from mq_stream_send).
    void (*send_done)(void *send_ctx, int canceled);
    void (*datagram)(void *conn_ctx, const uint8_t *data, uint32_t len);
    void (*datagram_state)(void *conn_ctx, int enabled, uint16_t max_send);
    void (*log)(void *host_ctx, const char *line);
} mq_callbacks;

/// Opens msquic and starts listening on UDP `port` (all addresses) with the PEM certificate and key. 0 on success, else
/// a message in `err`.
int mq_host_start(uint16_t port, const char *cert_file, const char *key_file, const char *alpn, uint32_t idle_ms,
                  const mq_callbacks *cb, void *host_ctx, char *err, size_t err_len);

/// Queues `len` bytes (copied) on a stream; `send_done(send_ctx)` follows. 0 when queued.
int mq_stream_send(void *stream, const uint8_t *data, uint32_t len, void *send_ctx);
/// Sends one datagram (copied). 0 when queued.
int mq_datagram_send(void *conn, const uint8_t *data, uint32_t len);
/// Aborts both directions of a stream.
void mq_stream_abort(void *stream);
void mq_conn_shutdown(void *conn);

#endif
