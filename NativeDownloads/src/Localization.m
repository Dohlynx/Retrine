#import "Localization.h"
#include <dlfcn.h>

NSString *SAPL(NSString *key,NSString *english) {
    // Do not cache a missing export: the companion can load before Vitrine.
    NSString *(*localize)(NSString *,NSString *)=dlsym(RTLD_DEFAULT,"SGL");
    return localize ? localize(key,english) : english;
}

NSString *SAPDeviceL(NSString *key) {
    static NSDictionary *strings;static dispatch_once_t once;
    dispatch_once(&once,^{
        strings=@{
            @"this_copy":@[@"This copy",@"이 사본"],
            @"other_copy":@[@"Other copy",@"다른 사본"],
            @"enabled":@[@"Offline enabled",@"오프라인 활성화됨"],
            @"disabled":@[@"Offline disabled",@"오프라인 비활성화됨"],
            @"not_registered":@[@"Not registered",@"등록되지 않음"],
            @"unconfirmed":@[@"Registration unconfirmed",@"등록 확인 안 됨"],
            @"received":@[@"received",@"수신됨"],
            @"unavailable":@[@"unavailable",@"사용 불가"],
            @"transport_error":@[@"transport error",@"통신 오류"],
            @"invalid_identities":@[@"The device response contains duplicate or invalid registrations. Nothing was changed.",@"기기 응답에 중복되거나 유효하지 않은 등록 정보가 있습니다. 변경하지 않았습니다."],
            @"snapshot_format":@[@"Last observed state (not proof of success)\nFree slots: %@ of %@ · Native slots: %@ of %@\nNative: %@ · Direct: %@",@"마지막으로 확인한 상태(성공을 의미하지 않음)\n사용 가능한 슬롯: %@ / %@ · 앱 슬롯: %@ / %@\n앱: %@ · 직접 응답: %@"],
        };
    });
    NSString *(*language)(void)=dlsym(RTLD_DEFAULT,"SGLanguage");
    return strings[key][language&&[language()isEqual:@"ko"]?1:0];
}
