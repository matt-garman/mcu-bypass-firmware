// Copyright (c) Matthew Garman.  All rights reserved.
// Licensed under the MIT License. See LICENSE in the project root for
// license information.

#ifndef BYPASS_STATIC_ASSERT_H__
#define BYPASS_STATIC_ASSERT_H__

#include <assert.h>

// static_assert() shim for xc8-cc
//   - XC8 v3.10 does not support C11, only C99, which does not have
//     static_assert() in <assert.h>
//   - this firmware makes extensive use of static_assert() compile-time
//     checks
//   - so here we alias static_assert() to _Static_assert(), which xc8 does
//     provide
#if !defined(static_assert)
#  define static_assert _Static_assert
#endif


#endif // BYPASS_STATIC_ASSERT_H__
