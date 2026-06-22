//
//  LibboxPlatformAdapter.h
//  MyVPNClean
//

#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>
#import <Libbox/Libbox.h>

NS_ASSUME_NONNULL_BEGIN

@interface LibboxPlatformAdapter : NSObject <LibboxPlatformInterface>

- (instancetype)initWithTunnelProvider:(NEPacketTunnelProvider *)tunnelProvider;

@end

NS_ASSUME_NONNULL_END
