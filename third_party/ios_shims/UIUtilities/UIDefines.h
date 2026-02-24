#ifndef UIUTILITIES_UIDEFINES_H
#define UIUTILITIES_UIDEFINES_H

#include <Availability.h>
#include <TargetConditionals.h>

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

#ifndef UIKIT_EXTERN
#if defined(__cplusplus)
#define UIKIT_EXTERN extern "C"
#else
#define UIKIT_EXTERN extern
#endif
#endif

#ifndef UIKIT_STATIC_INLINE
#define UIKIT_STATIC_INLINE static inline
#endif

#endif
