/* SPDX-License-Identifier: MIT */
#ifndef KOBO_NET_H
#define KOBO_NET_H
/* 1, wenn ein Netzwerk-ioctl die Host-Schnittstelle veraendern wuerde (wird dann verschluckt). */
int kobo_net_blocks(unsigned long request, const void *arg);
/* 1, wenn ein Schreibzugriff auf /proc/sys/net/... nach /dev/null umgeleitet werden soll. */
int kobo_net_hides_path(const char *path, int flags);
#endif
