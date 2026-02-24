#ifndef UIUTILITIES_UIGEOMETRY_H
#define UIUTILITIES_UIGEOMETRY_H

/*
 Compatibility shim for SDKs that reference UIUtilities/UIGeometry.h
 from UIKit public headers.
*/

#import <Foundation/Foundation.h>

typedef NS_OPTIONS(NSUInteger, UIRectEdge) {
    UIRectEdgeNone = 0,
    UIRectEdgeTop = 1 << 0,
    UIRectEdgeLeft = 1 << 1,
    UIRectEdgeBottom = 1 << 2,
    UIRectEdgeRight = 1 << 3,
    UIRectEdgeAll = UIRectEdgeTop | UIRectEdgeLeft | UIRectEdgeBottom | UIRectEdgeRight,
};

typedef NS_OPTIONS(NSUInteger, UIAxis) {
    UIAxisNeither = 0,
    UIAxisHorizontal = 1 << 0,
    UIAxisVertical = 1 << 1,
    UIAxisBoth = UIAxisHorizontal | UIAxisVertical,
};

#endif
