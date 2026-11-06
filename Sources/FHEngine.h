// Legge un file FreeHand con libfreehand e lo disegna in un PDF con le funzioni del Mac.
#import <Foundation/Foundation.h>

@interface FHConversion : NSObject
@property (nonatomic) BOOL ok;
@property (nonatomic, copy) NSString *error;
@property (nonatomic, copy) NSArray<NSString *> *notes;
@property (nonatomic) BOOL includedHiddenLayers;
@end

#ifdef __cplusplus
extern "C" {
#endif
BOOL FHIsSupported(NSString *path);
FHConversion *FHConvertToPDF(NSString *input, NSString *output, BOOL includeHiddenLayers);
FHConversion *FHConvertToAI(NSString *input, NSString *output);
#ifdef __cplusplus
}
#endif
