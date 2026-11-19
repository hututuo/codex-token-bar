#include "CSQLiteMemory.h"
#include <limits.h>
#include <malloc/malloc.h>
#include <pthread.h>
#include <sqlite3.h>
#include <stdlib.h>

/* SQLite schemas can outlive individual statements, but should not share
 * allocator pages with unrelated long-lived connections. Each synchronous
 * driver operation owns a zone. Escaping allocations retain that zone until
 * their actual free, even on another thread or after a retained handle expires.
 * Nothing here changes connections, transactions, caches or database files. */
typedef struct MemoryDomain {
    malloc_zone_t *zone;
    size_t allocations;
    int active;
    struct MemoryDomain *previous;
    struct MemoryDomain *next;
} MemoryDomain;

typedef union AllocationHeader {
    struct { MemoryDomain *domain; } info;
    max_align_t alignment;
} AllocationHeader;

static pthread_mutex_t zone_lock = PTHREAD_MUTEX_INITIALIZER;
static MemoryDomain global_domain = { .active = 1 };
static MemoryDomain *domains;
static _Thread_local MemoryDomain *current_domain;
static size_t live_bytes, allocation_count, zone_count;
static int installed;
static pthread_once_t installation_once = PTHREAD_ONCE_INIT;
static int installation_result = SQLITE_MISUSE;

static void destroy_if_unused(MemoryDomain *domain) {
    if (domain->allocations != 0) return;
    if (domain->zone) {
        malloc_destroy_zone(domain->zone);
        domain->zone = NULL;
        zone_count--;
    }
    if (!domain->active) {
        MemoryDomain **link = &domains;
        while (*link && *link != domain) link = &(*link)->next;
        if (*link) *link = domain->next;
        free(domain);
    }
}

static void *allocate(int size) {
    if (size <= 0 || size > INT_MAX - 64) return NULL;
    pthread_mutex_lock(&zone_lock);
    MemoryDomain *domain = current_domain ? current_domain : &global_domain;
    if (!domain->zone) {
        domain->zone = malloc_create_zone(0, 0);
        if (domain->zone) {
            malloc_set_zone_name(domain->zone, domain == &global_domain
                ? "TokenBar SQLite shared" : "TokenBar SQLite operation");
            zone_count++;
        }
    }
    AllocationHeader *header = domain->zone
        ? malloc_zone_malloc(domain->zone, (size_t)size + sizeof(AllocationHeader)) : NULL;
    if (header) {
        header->info.domain = domain;
        live_bytes += malloc_size(header) - sizeof(AllocationHeader);
        domain->allocations++;
        allocation_count++;
    }
    pthread_mutex_unlock(&zone_lock);
    return header ? header + 1 : NULL;
}

static void release(void *pointer) {
    if (!pointer) return;
    AllocationHeader *header = (AllocationHeader *)pointer - 1;
    pthread_mutex_lock(&zone_lock);
    MemoryDomain *domain = header->info.domain;
    live_bytes -= malloc_size(header) - sizeof(AllocationHeader);
    allocation_count--;
    domain->allocations--;
    malloc_zone_free(domain->zone, header);
    destroy_if_unused(domain);
    pthread_mutex_unlock(&zone_lock);
}

static void *resize(void *pointer, int size) {
    if (!pointer) return allocate(size);
    if (size <= 0) { release(pointer); return NULL; }
    if (size > INT_MAX - 64) return NULL;
    AllocationHeader *header = (AllocationHeader *)pointer - 1;
    pthread_mutex_lock(&zone_lock);
    MemoryDomain *domain = header->info.domain;
    size_t previous = malloc_size(header);
    AllocationHeader *result = malloc_zone_realloc(domain->zone, header,
        (size_t)size + sizeof(AllocationHeader));
    if (result) live_bytes = live_bytes - previous + malloc_size(result);
    pthread_mutex_unlock(&zone_lock);
    return result ? result + 1 : NULL;
}

static int allocation_size(void *pointer) {
    return pointer ? (int)(malloc_size((AllocationHeader *)pointer - 1) - sizeof(AllocationHeader)) : 0;
}
static int rounded_size(int size) {
    if (size <= 0 || size > INT_MAX - 64) return 0;
    return (size + 15) & ~15;
}
static int initialize(void *context) { (void)context; return SQLITE_OK; }
static void shutdown_allocator(void *context) { (void)context; }
static void install_once(void) {
    sqlite3_mem_methods methods = {
        allocate, release, resize, allocation_size, rounded_size,
        initialize, shutdown_allocator, NULL
    };
    installation_result = sqlite3_config(SQLITE_CONFIG_MALLOC, &methods);
    installed = installation_result == SQLITE_OK;
    /* Initialize any process-wide SQLite allocations outside operation zones. */
    if (installed) sqlite3_initialize();
}
int tb_sqlite_memory_install(void) {
    pthread_once(&installation_once, install_once);
    return installation_result;
}
int tb_sqlite_memory_is_installed(void) { return installed; }

void *tb_sqlite_memory_begin_scope(void) {
    if (!installed) return NULL;
    MemoryDomain *domain = calloc(1, sizeof(MemoryDomain));
    if (!domain) return NULL;
    pthread_mutex_lock(&zone_lock);
    domain->active = 1;
    domain->previous = current_domain;
    domain->next = domains;
    domains = domain;
    current_domain = domain;
    pthread_mutex_unlock(&zone_lock);
    return domain;
}
void tb_sqlite_memory_end_scope(void *scope) {
    if (!scope) return;
    pthread_mutex_lock(&zone_lock);
    MemoryDomain *domain = scope;
    /* Scope use is strictly synchronous, nested, and on one thread. */
    if (current_domain != domain) abort();
    current_domain = domain->previous;
    domain->active = 0;
    destroy_if_unused(domain);
    pthread_mutex_unlock(&zone_lock);
}
size_t tb_sqlite_memory_reclaim(void) {
    pthread_mutex_lock(&zone_lock);
    size_t released = global_domain.zone ? malloc_zone_pressure_relief(global_domain.zone, 0) : 0;
    for (MemoryDomain *domain = domains; domain; domain = domain->next) {
        if (domain->zone) released += malloc_zone_pressure_relief(domain->zone, 0);
    }
    pthread_mutex_unlock(&zone_lock);
    return released;
}
size_t tb_sqlite_memory_live_bytes(void) {
    pthread_mutex_lock(&zone_lock);
    size_t value = live_bytes;
    pthread_mutex_unlock(&zone_lock);
    return value;
}
size_t tb_sqlite_memory_allocation_count(void) {
    pthread_mutex_lock(&zone_lock);
    size_t value = allocation_count;
    pthread_mutex_unlock(&zone_lock);
    return value;
}
size_t tb_sqlite_memory_zone_count(void) {
    pthread_mutex_lock(&zone_lock);
    size_t value = zone_count;
    pthread_mutex_unlock(&zone_lock);
    return value;
}
