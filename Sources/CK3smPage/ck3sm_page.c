/*
Copyright The k3sm Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

#include "ck3sm_page.h"

#include <stdatomic.h>

_Static_assert(sizeof(_Atomic uint64_t) == 8, "an atomic page word is 8 bytes");
_Static_assert(_Alignof(_Atomic uint64_t) == 8, "an atomic page word is 8-byte aligned");
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "64-bit atomics are lock-free");

static inline const _Atomic uint64_t *word(const void *base, size_t offset) {
	return (const _Atomic uint64_t *)((const unsigned char *)base + offset);
}

uint64_t ck3sm_page_load_acquire(const void *base, size_t offset) {
	return atomic_load_explicit(word(base, offset), memory_order_acquire);
}

uint64_t ck3sm_page_load_relaxed(const void *base, size_t offset) {
	return atomic_load_explicit(word(base, offset), memory_order_relaxed);
}

void ck3sm_page_load_words_relaxed(const void *base, size_t offset, uint64_t *dst, size_t count) {
	const _Atomic uint64_t *w = word(base, offset);
	for (size_t i = 0; i < count; i++) {
		dst[i] = atomic_load_explicit(&w[i], memory_order_relaxed);
	}
}

void ck3sm_page_fence_acquire(void) {
	atomic_thread_fence(memory_order_acquire);
}
