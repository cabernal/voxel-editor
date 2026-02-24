#ifndef UIUTILITIES_UICOORDINATESPACE_H
#define UIUTILITIES_UICOORDINATESPACE_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@protocol UICoordinateSpace <NSObject>
@property(nonatomic, readonly) CGRect bounds;
- (CGPoint)convertPoint:(CGPoint)point toCoordinateSpace:(id<UICoordinateSpace>)coordinateSpace;
- (CGPoint)convertPoint:(CGPoint)point fromCoordinateSpace:(id<UICoordinateSpace>)coordinateSpace;
- (CGRect)convertRect:(CGRect)rect toCoordinateSpace:(id<UICoordinateSpace>)coordinateSpace;
- (CGRect)convertRect:(CGRect)rect fromCoordinateSpace:(id<UICoordinateSpace>)coordinateSpace;
@end

#endif
