/* SPDX-License-Identifier: MIT */
#ifndef KOBO_LOG_H
#define KOBO_LOG_H
/* Tuning-Wert: Umgebungsvariable NAME, sonst Zeile NAME=WERT in /dev/kobo/tuning, sonst fallback. */
int kobo_tunable(const char *name, int fallback);
#endif
