/* SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors */
/* SPDX-License-Identifier: MIT */
/* No logging implementation. External fail-stop callbacks replace secp defaults. */
#ifndef ZHWW_STDIO_H
#define ZHWW_STDIO_H
#include <stddef.h>
typedef struct zhww_unimplemented_FILE FILE;
extern FILE *stderr;
int fprintf(FILE *, const char *, ...);
int printf(const char *, ...);
#endif
