/* No target heap implementation: unused allocating secp APIs must be GC'd. */
#ifndef ZHWW_STDLIB_H
#define ZHWW_STDLIB_H
#include <stddef.h>
void *malloc(size_t);
void free(void *);
_Noreturn void abort(void);
#endif
