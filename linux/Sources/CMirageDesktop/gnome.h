// Internal: the process's D-Bus signal thread (md.c), shared by GNOME's sessions.
#ifndef MIRAGE_GNOME_H
#define MIRAGE_GNOME_H

/// Starts, once, the thread that runs the default GLib main context, where subscribed D-Bus signals arrive.
void md_dbus_thread(void);

#endif
