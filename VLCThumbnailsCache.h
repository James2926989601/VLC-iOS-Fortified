/*****************************************************************************
 * VLCThumbnailsCache.h
 * VLC for iOS
 *****************************************************************************
 * Copyright (c) 2013-2026 VideoLAN. All rights reserved.
 * $Id$
 *
 * Authors: Gleb Pinigin <gpinigin # gmail.com>
 *          Felix Paul Kühne <fkuehne # videolan.org>
 *          Carola Nitz <caro # videolan.org>
 *
 * Refer to the COPYING file of the official project for license.
 *****************************************************************************/

@interface VLCThumbnailsCache : NSObject

// Preserves source pixel dimensions.
+ (nullable UIImage *)thumbnailForURL:(nullable NSURL *)url;
// Reserved for non-artwork thumbnails that explicitly permit downsampling.
+ (nullable UIImage *)thumbnailForURL:(nullable NSURL *)url maxPixelSize:(CGFloat)maxPixelSize;
+ (void)invalidateThumbnailForURL:(nullable NSURL *)url;

@end
