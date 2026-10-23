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

#ifndef CK3SM_PAGE_H
#define CK3SM_PAGE_H

#include <stddef.h>
#include <stdint.h>

/*
 * The seqlock primitives of the budget page reader, in C11 atomics. The
 * writer stores seq odd, every body word, seq even, then notifyEpoch, each
 * an 8-byte atomic store. A reader loads seq acquiring, the body words
 * relaxed, issues an acquire fence, and reloads seq relaxed; equal even
 * values on both sides make the copy stable. Every offset is a byte offset
 * from base, the start of a read-only page mapping, and is 8-byte aligned.
 * Decoding stays in Swift.
 */

/* Loads the 64-bit word at base + offset with memory_order_acquire. */
uint64_t ck3sm_page_load_acquire(const void *base, size_t offset);

/* Loads the 64-bit word at base + offset with memory_order_relaxed. */
uint64_t ck3sm_page_load_relaxed(const void *base, size_t offset);

/* Loads count consecutive 64-bit words starting at base + offset, each
 * with memory_order_relaxed, into dst. */
void ck3sm_page_load_words_relaxed(const void *base, size_t offset, uint64_t *dst, size_t count);

/* atomic_thread_fence(memory_order_acquire). */
void ck3sm_page_fence_acquire(void);

#endif
