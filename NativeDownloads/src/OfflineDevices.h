#pragma once
#import <Foundation/Foundation.h>
void SAPPreviewOfflineDeviceSlots(void (^completion)(NSDictionary *plan,NSString *error));
// The existing settings bridge transports this opaque array unchanged. Cache
// identifiers are not accepted: use selection_token from the reviewed plan.
void SAPReleaseOfflineDeviceSlots(NSString *planID,NSArray<NSString *> *selectionTokens,
                                  void (^completion)(NSDictionary *result,NSString *error));
void SAPEnableOfflineOnCurrentDevice(void (^completion)(NSDictionary *result,NSString *error));
#ifdef SAP_TESTING
void SAPOfflineDevicesTestEnvironment(Class protocolClass,void (^provider)(void (^)(NSDictionary *)));
#endif
