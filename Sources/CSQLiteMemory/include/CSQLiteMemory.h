#ifndef TOKENBAR_SQLITE_MEMORY_H
#define TOKENBAR_SQLITE_MEMORY_H
#include <stddef.h>

/* Call once, before opening SQLite. A late call safely returns SQLITE_MISUSE;
 * it never shuts SQLite down or replaces a live allocator. */
int tb_sqlite_memory_install(void);
size_t tb_sqlite_memory_reclaim(void);
int tb_sqlite_memory_is_installed(void);
size_t tb_sqlite_memory_live_bytes(void);
size_t tb_sqlite_memory_allocation_count(void);
/* Synchronous/thread-local scope only. Allocations may outlive the scope and
 * be freed on any thread; their zone closes only after the final real free. */
void *tb_sqlite_memory_begin_scope(void);
void tb_sqlite_memory_end_scope(void *scope);
size_t tb_sqlite_memory_zone_count(void);
#endif
