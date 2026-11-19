#include "CSQLiteMemory.h"
#include <limits.h>
#include <malloc/malloc.h>
#include <pthread.h>
#include <sqlite3.h>

/*
 * A large historical SQLite schema consists of hundreds of thousands of small
 * allocations. Sharing their pages with long-lived UI objects prevents malloc
 * from returning those pages after sqlite3_close. Keep SQLite's native memory
 * in one ordinary Darwin zone, using SQLite's supported allocator interface.
 * File formats, caches, connection ownership and transactions are unchanged.
 */
static pthread_mutex_t zone_lock = PTHREAD_MUTEX_INITIALIZER;
static malloc_zone_t *sqlite_zone;
static size_t live_bytes;
static size_t allocation_count;
static int installed;
static pthread_once_t installation_once = PTHREAD_ONCE_INIT;
static int installation_result = SQLITE_MISUSE;

static void *allocate(int size) {
    if (size <= 0) return NULL;
    pthread_mutex_lock(&zone_lock);
    if (!sqlite_zone) {
        sqlite_zone = malloc_create_zone(0, 0);
        if (sqlite_zone) malloc_set_zone_name(sqlite_zone, "TokenBar SQLite");
    }
    void *pointer = sqlite_zone ? malloc_zone_malloc(sqlite_zone, (size_t)size) : NULL;
    if (pointer) {
        live_bytes += malloc_size(pointer);
        allocation_count++;
    }
    pthread_mutex_unlock(&zone_lock);
    return pointer;
}

static void release(void *pointer) {
    if (!pointer) return;
    pthread_mutex_lock(&zone_lock);
    live_bytes -= malloc_size(pointer);
    allocation_count--;
    malloc_zone_free(sqlite_zone, pointer);
    if (allocation_count == 0) {
        malloc_destroy_zone(sqlite_zone);
        sqlite_zone = NULL;
    }
    pthread_mutex_unlock(&zone_lock);
}

static void *resize(void *pointer, int size) {
    if (!pointer) return allocate(size);
    if (size <= 0) { release(pointer); return NULL; }
    pthread_mutex_lock(&zone_lock);
    size_t previous = malloc_size(pointer);
    void *result = malloc_zone_realloc(sqlite_zone, pointer, (size_t)size);
    if (result) live_bytes = live_bytes - previous + malloc_size(result);
    pthread_mutex_unlock(&zone_lock);
    return result;
}

static int allocation_size(void *pointer) {
    return pointer ? (int)malloc_size(pointer) : 0;
}

static int rounded_size(int size) {
    if (size <= 0 || size > INT_MAX - 15) return 0;
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
}

int tb_sqlite_memory_install(void) {
    pthread_once(&installation_once, install_once);
    return installation_result;
}

int tb_sqlite_memory_is_installed(void) { return installed; }

size_t tb_sqlite_memory_reclaim(void) {
    pthread_mutex_lock(&zone_lock);
    size_t released = sqlite_zone ? malloc_zone_pressure_relief(sqlite_zone, 0) : 0;
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
