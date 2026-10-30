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


#include "ck3sm_test_wake.h"

#include <errno.h>
#include <os/os_sync_wait_on_address.h>

int ck3sm_test_wake_all(void *addr) {
	if (os_sync_wake_by_address_all(addr, sizeof(uint64_t), OS_SYNC_WAKE_BY_ADDRESS_SHARED) == 0) {
		return 0;
	}
	return errno;
}
