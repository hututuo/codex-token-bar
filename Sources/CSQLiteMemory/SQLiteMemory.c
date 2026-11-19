#include "CSQLiteMemory.h"
#include <limits.h>
#include <pthread.h>
#include <sqlite3.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

/* Short-lived, million-allocation schemas must not share pages with the UI or
 * unrelated SQLite connections. Small blocks use bounded mmap slabs; the last
 * free unmaps that slab immediately, even if another slab has surviving data.
 * This avoids Darwin malloc-zone metadata and region retention at this scale. */
static const size_t classes[] = {
    32,48,64,80,96,112,128,160,192,224,256,320,384,448,512,
    640,768,896,1024,1280,1536,1792,2048,2560,3072,3584,4096,
    5120,6144,7168,8192,10240,12288,14336,16384
};
#define CLASS_COUNT (sizeof(classes) / sizeof(classes[0]))
typedef struct Region Region;
typedef struct MemoryDomain {
    Region *available[CLASS_COUNT];
    size_t allocations;
    int active;
    struct MemoryDomain *previous;
} MemoryDomain;

typedef union AllocationHeader {
    struct { Region *region; } info;
    max_align_t alignment;
} AllocationHeader;
struct Region {
    MemoryDomain *domain;
    Region *next, *previous;
    void *free_list;
    size_t mapping_size, stride, capacity, used;
    size_t class_index;
    int listed;
};

static pthread_mutex_t memory_lock = PTHREAD_MUTEX_INITIALIZER;
static MemoryDomain global_domain = { .active = 1 };
static _Thread_local MemoryDomain *current_domain;
static size_t page_size, live_bytes, allocation_count, region_count, mapped_bytes;
static int installed;
static pthread_once_t installation_once = PTHREAD_ONCE_INIT;
static int installation_result = SQLITE_MISUSE;

static size_t aligned(size_t size, size_t alignment) {
    return (size + alignment - 1) / alignment * alignment;
}
static void remove_available(Region *region) {
    if (!region->listed) return;
    if (region->previous) region->previous->next = region->next;
    else region->domain->available[region->class_index] = region->next;
    if (region->next) region->next->previous = region->previous;
    region->next = region->previous = NULL;
    region->listed = 0;
}
static void add_available(Region *region) {
    if (region->listed || region->class_index == CLASS_COUNT) return;
    Region **head = &region->domain->available[region->class_index];
    region->next = *head;
    region->previous = NULL;
    if (*head) (*head)->previous = region;
    *head = region;
    region->listed = 1;
}
static void *allocate_locked(MemoryDomain *domain, int size) {
    if (size <= 0 || size > INT_MAX - 65536) return NULL;
    size_t needed = (size_t)size + sizeof(AllocationHeader), index = 0;
    while (index < CLASS_COUNT && classes[index] < needed) index++;
    Region *region = index < CLASS_COUNT ? domain->available[index] : NULL;
    if (!region) {
        size_t offset = aligned(sizeof(Region), _Alignof(AllocationHeader));
        size_t stride = index < CLASS_COUNT ? classes[index] : aligned(needed, 16);
        size_t length = aligned(index < CLASS_COUNT ? 65536 : offset + stride, page_size);
        void *mapping = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (mapping == MAP_FAILED) return NULL;
        region = mapping;
        region->domain = domain;
        region->mapping_size = length;
        region->stride = stride;
        region->class_index = index;
        region->capacity = (length - offset) / stride;
        unsigned char *base = (unsigned char *)mapping + offset;
        for (size_t slot = 0; slot < region->capacity; slot++) {
            void *block = base + slot * stride;
            *(void **)block = region->free_list;
            region->free_list = block;
        }
        add_available(region);
        region_count++;
        mapped_bytes += length;
    }
    AllocationHeader *header = region->free_list;
    region->free_list = *(void **)header;
    header->info.region = region;
    region->used++;
    domain->allocations++;
    allocation_count++;
    live_bytes += region->stride - sizeof(AllocationHeader);
    if (!region->free_list) remove_available(region);
    return header + 1;
}
static void release_locked(void *pointer) {
    AllocationHeader *header = (AllocationHeader *)pointer - 1;
    Region *region = header->info.region;
    MemoryDomain *domain = region->domain;
    live_bytes -= region->stride - sizeof(AllocationHeader);
    allocation_count--;
    domain->allocations--;
    region->used--;
    if (region->used == 0) {
        remove_available(region);
        size_t length = region->mapping_size;
        munmap(region, length);
        mapped_bytes -= length;
        region_count--;
        if (!domain->active && domain->allocations == 0) free(domain);
    } else {
        *(void **)header = region->free_list;
        region->free_list = header;
        add_available(region);
    }
}
static void *allocate(int size) {
    pthread_mutex_lock(&memory_lock);
    void *pointer = allocate_locked(current_domain ? current_domain : &global_domain, size);
    pthread_mutex_unlock(&memory_lock);
    return pointer;
}
static void release(void *pointer) {
    if (!pointer) return;
    pthread_mutex_lock(&memory_lock);
    release_locked(pointer);
    pthread_mutex_unlock(&memory_lock);
}
static int allocation_size(void *pointer) {
    if (!pointer) return 0;
    Region *region = ((AllocationHeader *)pointer - 1)->info.region;
    return (int)(region->stride - sizeof(AllocationHeader));
}
static void *resize(void *pointer, int size) {
    if (!pointer) return allocate(size);
    if (size <= 0) { release(pointer); return NULL; }
    pthread_mutex_lock(&memory_lock);
    int previous = allocation_size(pointer);
    if (size <= previous && size > previous / 2) {
        pthread_mutex_unlock(&memory_lock);
        return pointer;
    }
    MemoryDomain *domain = ((AllocationHeader *)pointer - 1)->info.region->domain;
    void *result = allocate_locked(domain, size);
    if (result) {
        memcpy(result, pointer, (size_t)(size < previous ? size : previous));
        release_locked(pointer);
    }
    pthread_mutex_unlock(&memory_lock);
    return result;
}
static int rounded_size(int size) {
    if (size <= 0 || size > INT_MAX - 65536) return 0;
    return (size + 15) & ~15;
}
static int initialize(void *context) { (void)context; return SQLITE_OK; }
static void shutdown_allocator(void *context) { (void)context; }
static void install_once(void) {
    long system_page_size = sysconf(_SC_PAGESIZE);
    page_size = system_page_size > 0 ? (size_t)system_page_size : 16384;
    sqlite3_mem_methods methods = {
        allocate, release, resize, allocation_size, rounded_size,
        initialize, shutdown_allocator, NULL
    };
    installation_result = sqlite3_config(SQLITE_CONFIG_MALLOC, &methods);
    installed = installation_result == SQLITE_OK;
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
    domain->active = 1;
    domain->previous = current_domain;
    current_domain = domain;
    return domain;
}
void tb_sqlite_memory_end_scope(void *scope) {
    if (!scope) return;
    pthread_mutex_lock(&memory_lock);
    MemoryDomain *domain = scope;
    if (current_domain != domain) abort();
    current_domain = domain->previous;
    domain->active = 0;
    if (domain->allocations == 0) free(domain);
    pthread_mutex_unlock(&memory_lock);
}
/* Empty slabs are already unmapped synchronously by release_locked. */
size_t tb_sqlite_memory_reclaim(void) { return 0; }
size_t tb_sqlite_memory_live_bytes(void) {
    pthread_mutex_lock(&memory_lock);
    size_t value = live_bytes;
    pthread_mutex_unlock(&memory_lock);
    return value;
}
size_t tb_sqlite_memory_allocation_count(void) {
    pthread_mutex_lock(&memory_lock);
    size_t value = allocation_count;
    pthread_mutex_unlock(&memory_lock);
    return value;
}
size_t tb_sqlite_memory_zone_count(void) {
    pthread_mutex_lock(&memory_lock);
    size_t value = region_count;
    pthread_mutex_unlock(&memory_lock);
    return value;
}
size_t tb_sqlite_memory_mapped_bytes(void) {
    pthread_mutex_lock(&memory_lock);
    size_t value = mapped_bytes;
    pthread_mutex_unlock(&memory_lock);
    return value;
}
