//
//  LibboxPlatformAdapter.m
//  MyVPNPacketTunnel
//

#import "LibboxPlatformAdapter.h"
#import <Network/Network.h>

static NSString * const MyVPNLibboxPlatformErrorDomain = @"MyVPN.LibboxPlatform";

@interface LibboxNetworkInterfaceIteratorImpl : NSObject <LibboxNetworkInterfaceIterator>
- (instancetype)initWithInterfaces:(NSArray<LibboxNetworkInterface *> *)interfaces;
@end

@interface LibboxPlatformAdapter ()

@property (nonatomic, strong) NEPacketTunnelProvider *tunnelProvider;
@property (nonatomic, strong, nullable) NEPacketTunnelNetworkSettings *networkSettings;
@property (nonatomic, assign, nullable) nw_path_monitor_t pathMonitor;
@property (nonatomic, strong) dispatch_queue_t monitorQueue;
@property (nonatomic, strong) NSArray<LibboxNetworkInterface *> *currentInterfaces;

@end

@implementation LibboxPlatformAdapter

- (instancetype)initWithTunnelProvider:(NEPacketTunnelProvider *)tunnelProvider {
    self = [super init];
    if (self) {
        _tunnelProvider = tunnelProvider;
        _monitorQueue = dispatch_queue_create("MyVPN.LibboxPlatformAdapter.monitor", DISPATCH_QUEUE_SERIAL);
        _currentInterfaces = @[];
        _pathMonitor = nil;
    }
    return self;
}

- (void)dealloc {
    if (_pathMonitor != nil) {
        nw_path_monitor_cancel(_pathMonitor);
        _pathMonitor = nil;
    }
}

#pragma mark - LibboxPlatformInterface

- (BOOL)autoDetectInterfaceControl:(int32_t)fd error:(NSError * _Nullable __autoreleasing * _Nullable)error {
    return NO;
}

- (void)clearDNSCache {
    if (self.networkSettings == nil) {
        NSLog(@"[MyVPN][LibboxPlatform] clearDNSCache skipped: no network settings");
        return;
    }

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    [self.tunnelProvider setTunnelNetworkSettings:nil completionHandler:^(NSError * _Nullable _) {
        [self.tunnelProvider setTunnelNetworkSettings:self.networkSettings completionHandler:^(NSError * _Nullable _) {
            dispatch_semaphore_signal(semaphore);
        }];
    }];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    NSLog(@"[MyVPN][LibboxPlatform] clearDNSCache done");
}

- (BOOL)closeDefaultInterfaceMonitor:(id<LibboxInterfaceUpdateListener> _Nullable)listener
                               error:(NSError * _Nullable __autoreleasing * _Nullable)error {
    if (self.pathMonitor != nil) {
        nw_path_monitor_cancel(self.pathMonitor);
        self.pathMonitor = nil;
    }

    self.currentInterfaces = @[];
    return YES;
}

- (BOOL)findConnectionOwner:(int32_t)ipProtocol
              sourceAddress:(NSString * _Nullable)sourceAddress
                 sourcePort:(int32_t)sourcePort
         destinationAddress:(NSString * _Nullable)destinationAddress
            destinationPort:(int32_t)destinationPort
                      ret0_:(int32_t * _Nullable)ret0_
                      error:(NSError * _Nullable __autoreleasing * _Nullable)error {
    if (ret0_ != NULL) {
        *ret0_ = -1;
    }
    return NO;
}

- (id<LibboxNetworkInterfaceIterator> _Nullable)getInterfaces:(NSError * _Nullable __autoreleasing * _Nullable)error {
    return [[LibboxNetworkInterfaceIteratorImpl alloc] initWithInterfaces:self.currentInterfaces ?: @[]];
}

- (BOOL)includeAllNetworks {
    return NO;
}

- (BOOL)openTun:(id<LibboxTunOptions> _Nullable)options
          ret0_:(int32_t * _Nullable)ret0_
          error:(NSError * _Nullable __autoreleasing * _Nullable)error {
    if (options == nil) {
        if (ret0_ != NULL) {
            *ret0_ = -1;
        }
        if (error != NULL) {
            *error = [NSError errorWithDomain:MyVPNLibboxPlatformErrorDomain
                                         code:-1
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Nil tun options"
            }];
        }
        return NO;
    }

    if (ret0_ == NULL) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:MyVPNLibboxPlatformErrorDomain
                                         code:-2
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Nil return pointer"
            }];
        }
        return NO;
    }

    NEPacketTunnelNetworkSettings *settings =
        [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:@"127.0.0.1"];

    if ([options getAutoRoute]) {
        settings.MTU = @([options getMTU]);

        NSMutableArray<NSString *> *ipv4Addresses = [NSMutableArray array];
        NSMutableArray<NSString *> *ipv4Masks = [NSMutableArray array];

        @try {
            id iterator = [options getInet4Address];
            while (iterator != nil && [iterator hasNext]) {
                id prefix = [iterator next];
                if (prefix != nil) {
                    NSString *address = [prefix address];
                    NSString *mask = [prefix mask];
                    if (address.length > 0 && mask.length > 0) {
                        [ipv4Addresses addObject:address];
                        [ipv4Masks addObject:mask];
                    }
                }
            }
        } @catch (__unused NSException *exception) {
        }

        if (ipv4Addresses.count > 0 && ipv4Addresses.count == ipv4Masks.count) {
            NEIPv4Settings *ipv4Settings =
                [[NEIPv4Settings alloc] initWithAddresses:ipv4Addresses subnetMasks:ipv4Masks];

            NSMutableArray<NEIPv4Route *> *includedRoutes = [NSMutableArray array];
            NSMutableArray<NEIPv4Route *> *excludedRoutes = [NSMutableArray array];

            @try {
                id routeIterator = [options getInet4RouteAddress];
                while (routeIterator != nil && [routeIterator hasNext]) {
                    id prefix = [routeIterator next];
                    if (prefix != nil) {
                        NSString *address = [prefix address];
                        NSString *mask = [prefix mask];
                        if (address.length > 0 && mask.length > 0) {
                            [includedRoutes addObject:[[NEIPv4Route alloc] initWithDestinationAddress:address
                                                                                           subnetMask:mask]];
                        }
                    }
                }
            } @catch (__unused NSException *exception) {
            }

            if (includedRoutes.count == 0) {
                [includedRoutes addObject:[NEIPv4Route defaultRoute]];
            }

            @try {
                id excludeIterator = [options getInet4RouteExcludeAddress];
                while (excludeIterator != nil && [excludeIterator hasNext]) {
                    id prefix = [excludeIterator next];
                    if (prefix != nil) {
                        NSString *address = [prefix address];
                        NSString *mask = [prefix mask];
                        if (address.length > 0 && mask.length > 0) {
                            [excludedRoutes addObject:[[NEIPv4Route alloc] initWithDestinationAddress:address
                                                                                           subnetMask:mask]];
                        }
                    }
                }
            } @catch (__unused NSException *exception) {
            }

            ipv4Settings.includedRoutes = includedRoutes;
            if (excludedRoutes.count > 0) {
                ipv4Settings.excludedRoutes = excludedRoutes;
            }

            settings.IPv4Settings = ipv4Settings;
        }

        NSMutableArray<NSString *> *ipv6Addresses = [NSMutableArray array];
        NSMutableArray<NSNumber *> *ipv6Prefixes = [NSMutableArray array];

        @try {
            id iterator = [options getInet6Address];
            while (iterator != nil && [iterator hasNext]) {
                id prefix = [iterator next];
                if (prefix != nil) {
                    NSString *address = [prefix address];
                    NSNumber *networkPrefix = @([prefix prefix]);
                    if (address.length > 0) {
                        [ipv6Addresses addObject:address];
                        [ipv6Prefixes addObject:networkPrefix];
                    }
                }
            }
        } @catch (__unused NSException *exception) {
        }

        if (ipv6Addresses.count > 0 && ipv6Addresses.count == ipv6Prefixes.count) {
            NEIPv6Settings *ipv6Settings =
                [[NEIPv6Settings alloc] initWithAddresses:ipv6Addresses
                                     networkPrefixLengths:ipv6Prefixes];

            NSMutableArray<NEIPv6Route *> *includedRoutes = [NSMutableArray array];
            NSMutableArray<NEIPv6Route *> *excludedRoutes = [NSMutableArray array];

            @try {
                id routeIterator = [options getInet6RouteAddress];
                while (routeIterator != nil && [routeIterator hasNext]) {
                    id prefix = [routeIterator next];
                    if (prefix != nil) {
                        NSString *address = [prefix address];
                        NSNumber *networkPrefix = @([prefix prefix]);
                        if (address.length > 0) {
                            [includedRoutes addObject:[[NEIPv6Route alloc] initWithDestinationAddress:address
                                                                                    networkPrefixLength:networkPrefix]];
                        }
                    }
                }
            } @catch (__unused NSException *exception) {
            }

            if (includedRoutes.count == 0) {
                [includedRoutes addObject:[NEIPv6Route defaultRoute]];
            }

            @try {
                id excludeIterator = [options getInet6RouteExcludeAddress];
                while (excludeIterator != nil && [excludeIterator hasNext]) {
                    id prefix = [excludeIterator next];
                    if (prefix != nil) {
                        NSString *address = [prefix address];
                        NSNumber *networkPrefix = @([prefix prefix]);
                        if (address.length > 0) {
                            [excludedRoutes addObject:[[NEIPv6Route alloc] initWithDestinationAddress:address
                                                                                    networkPrefixLength:networkPrefix]];
                        }
                    }
                }
            } @catch (__unused NSException *exception) {
            }

            ipv6Settings.includedRoutes = includedRoutes;
            if (excludedRoutes.count > 0) {
                ipv6Settings.excludedRoutes = excludedRoutes;
            }

            settings.IPv6Settings = ipv6Settings;
        }
    }

    self.networkSettings = settings;

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSError *applyError = nil;

    [self.tunnelProvider setTunnelNetworkSettings:settings
                                completionHandler:^(NSError * _Nullable completionError) {
        applyError = completionError;
        dispatch_semaphore_signal(semaphore);
    }];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    if (applyError != nil) {
        *ret0_ = -1;
        if (error != NULL) {
            *error = applyError;
        }
        NSLog(@"[MyVPN][LibboxPlatform] openTun failed while applying network settings: %@",
              applyError.localizedDescription);
        return NO;
    }

    int32_t fd = [self tunnelFileDescriptorFromPacketFlow:self.tunnelProvider.packetFlow];
    if (fd < 0) {
        fd = LibboxGetTunnelFileDescriptor();
    }

    if (fd >= 0) {
        *ret0_ = fd;
        NSLog(@"[MyVPN][LibboxPlatform] openTun success, fd=%d", fd);
        return YES;
    }

    *ret0_ = -1;

    if (error != NULL) {
        *error = [NSError errorWithDomain:MyVPNLibboxPlatformErrorDomain
                                     code:-3
                                 userInfo:@{
            NSLocalizedDescriptionKey: @"Missing file descriptor after tunnel network setup"
        }];
    }

    NSLog(@"[MyVPN][LibboxPlatform] openTun failed: missing file descriptor");
    return NO;
}

- (NSString * _Nonnull)packageNameByUid:(int32_t)uid
                                  error:(NSError * _Nullable __autoreleasing * _Nullable)error {
    return @"";
}

- (LibboxWIFIState * _Nullable)readWIFIState {
    return nil;
}

- (BOOL)sendNotification:(LibboxNotification * _Nullable)notification
                   error:(NSError * _Nullable __autoreleasing * _Nullable)error {
    return YES;
}

- (BOOL)startDefaultInterfaceMonitor:(id<LibboxInterfaceUpdateListener> _Nullable)listener
                               error:(NSError * _Nullable __autoreleasing * _Nullable)error {
    if (self.pathMonitor != nil) {
        nw_path_monitor_cancel(self.pathMonitor);
        self.pathMonitor = nil;
    }

    nw_path_monitor_t monitor = nw_path_monitor_create();
    self.pathMonitor = monitor;

    __weak typeof(self) weakSelf = self;

    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t  _Nonnull path) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil) {
            return;
        }

        NSMutableArray<LibboxNetworkInterface *> *interfaces = [NSMutableArray array];
        __block NSString *defaultName = @"";
        __block int32_t defaultIndex = -1;

        nw_path_enumerate_interfaces(path, ^bool(nw_interface_t  _Nonnull interface) {
            LibboxNetworkInterface *item = [[LibboxNetworkInterface alloc] init];
            item.name = [NSString stringWithUTF8String:nw_interface_get_name(interface)];
            item.index = (int32_t)nw_interface_get_index(interface);

            switch (nw_interface_get_type(interface)) {
                case nw_interface_type_wifi:
                    item.type = LibboxInterfaceTypeWIFI;
                    break;
                case nw_interface_type_cellular:
                    item.type = LibboxInterfaceTypeCellular;
                    break;
                case nw_interface_type_wired:
                    item.type = LibboxInterfaceTypeEthernet;
                    break;
                default:
                    item.type = LibboxInterfaceTypeOther;
                    break;
            }

            if (defaultIndex == -1) {
                defaultName = item.name ?: @"";
                defaultIndex = item.index;
            }

            [interfaces addObject:item];
            return true;
        });

        self.currentInterfaces = interfaces;

        if (listener == nil) {
            return;
        }

        if (nw_path_get_status(path) != nw_path_status_satisfied || interfaces.count == 0) {
            [listener updateDefaultInterface:@""
                              interfaceIndex:-1
                                 isExpensive:NO
                               isConstrained:NO];
            return;
        }

        [listener updateDefaultInterface:defaultName
                          interfaceIndex:defaultIndex
                             isExpensive:nw_path_is_expensive(path)
                           isConstrained:nw_path_is_constrained(path)];
    });

    nw_path_monitor_set_queue(monitor, self.monitorQueue);
    nw_path_monitor_start(monitor);

    return YES;
}

- (BOOL)uidByPackageName:(NSString * _Nullable)packageName
                   ret0_:(int32_t * _Nullable)ret0_
                   error:(NSError * _Nullable __autoreleasing * _Nullable)error {
    if (ret0_ != NULL) {
        *ret0_ = -1;
    }
    return NO;
}

- (BOOL)underNetworkExtension {
    return YES;
}

- (BOOL)usePlatformAutoDetectInterfaceControl {
    return NO;
}

- (BOOL)useProcFS {
    return NO;
}

- (void)writeLog:(NSString * _Nullable)message {
    NSLog(@"[MyVPN][Libbox] %@", message ?: @"");
}

#pragma mark - Private

- (int32_t)tunnelFileDescriptorFromPacketFlow:(NEPacketTunnelFlow *)packetFlow {
    if (packetFlow == nil) {
        return -1;
    }

    NSArray<NSString *> *keyPaths = @[
        @"socket.fileDescriptor",
        @"_socket.fileDescriptor"
    ];

    for (NSString *keyPath in keyPaths) {
        @try {
            id value = [packetFlow valueForKeyPath:keyPath];
            if ([value isKindOfClass:[NSNumber class]]) {
                int32_t fd = (int32_t)[(NSNumber *)value intValue];
                if (fd >= 0) {
                    return fd;
                }
            }
        } @catch (__unused NSException *exception) {
        }
    }

    NSArray<NSString *> *socketKeys = @[
        @"socket",
        @"_socket"
    ];

    for (NSString *socketKey in socketKeys) {
        @try {
            id socketObject = [packetFlow valueForKey:socketKey];
            if (socketObject != nil && [socketObject respondsToSelector:@selector(fileDescriptor)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id value = [socketObject performSelector:@selector(fileDescriptor)];
#pragma clang diagnostic pop
                if ([value isKindOfClass:[NSNumber class]]) {
                    int32_t fd = (int32_t)[(NSNumber *)value intValue];
                    if (fd >= 0) {
                        return fd;
                    }
                }
            }
        } @catch (__unused NSException *exception) {
        }
    }

    return -1;
}

@end

@implementation LibboxNetworkInterfaceIteratorImpl {
    NSArray<LibboxNetworkInterface *> *_interfaces;
    NSUInteger _index;
}

- (instancetype)initWithInterfaces:(NSArray<LibboxNetworkInterface *> *)interfaces {
    self = [super init];
    if (self) {
        _interfaces = [interfaces copy];
        _index = 0;
    }
    return self;
}

- (BOOL)hasNext {
    return _index < _interfaces.count;
}

- (id _Nullable)next {
    if (_index >= _interfaces.count) {
        return nil;
    }

    id value = _interfaces[_index];
    _index += 1;
    return value;
}

@end
