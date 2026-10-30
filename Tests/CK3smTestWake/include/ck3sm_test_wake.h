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


#ifndef CK3SM_TEST_WAKE_H
#define CK3SM_TEST_WAKE_H

#include <stdint.h>

/*
 * The wake half of the page's change notification, for the tests' stand-in
 * writer only: the SDK reads the page and never writes or wakes. Wakes every
 * waiter blocked on the 8-byte word at addr, with the shared-memory flag the
 * reader's wait uses. Returns 0, or the errno of the call (ENOENT when no
 * thread was waiting).
 */
int ck3sm_test_wake_all(void *addr);

#endif
