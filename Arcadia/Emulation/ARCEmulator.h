#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

/// ID dei pulsanti RetroPad (libretro).
typedef NS_ENUM(NSInteger, ARCButton) {
    ARCButtonB NS_SWIFT_NAME(b) = 0,
    ARCButtonY NS_SWIFT_NAME(y) = 1,
    ARCButtonSelect NS_SWIFT_NAME(select) = 2,
    ARCButtonStart NS_SWIFT_NAME(start) = 3,
    ARCButtonUp NS_SWIFT_NAME(up) = 4,
    ARCButtonDown NS_SWIFT_NAME(down) = 5,
    ARCButtonLeft NS_SWIFT_NAME(left) = 6,
    ARCButtonRight NS_SWIFT_NAME(right) = 7,
    ARCButtonA NS_SWIFT_NAME(a) = 8,
    ARCButtonX NS_SWIFT_NAME(x) = 9,
    ARCButtonL NS_SWIFT_NAME(l) = 10,
    ARCButtonR NS_SWIFT_NAME(r) = 11,
    ARCButtonL2 NS_SWIFT_NAME(l2) = 12,
    ARCButtonR2 NS_SWIFT_NAME(r2) = 13,
    ARCButtonL3 NS_SWIFT_NAME(l3) = 14,
    ARCButtonR3 NS_SWIFT_NAME(r3) = 15
};

typedef NS_ENUM(NSInteger, ARCInputSource) {
    ARCInputSourceTouch = 0,
    ARCInputSourceController = 1
};

/// Frontend libretro: carica un core (.framework), lo esegue su un thread dedicato,
/// disegna con OpenGL ES 3 su un CAEAGLLayer e riproduce l'audio con AVAudioEngine.
/// Può esistere una sola istanza attiva alla volta.
@interface ARCEmulator : NSObject

- (instancetype)initWithCorePath:(NSString *)corePath
                 systemDirectory:(NSString *)systemDirectory
                   saveDirectory:(NSString *)saveDirectory NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Layer su cui disegnare. Va impostato (dal main thread) prima di start.
@property (nonatomic, strong, nullable) CAEAGLLayer *layer;
/// Velocità: 1, 2, 3, 4...
@property (atomic) double speed;
@property (atomic) BOOL smoothFiltering;
/// Opzioni core forzate (chiave -> valore).
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *optionOverrides;
/// Dispositivo da collegare alla porta 1 (RETRO_DEVICE_*), 1 = joypad.
@property (nonatomic) unsigned portDevice;
/// Messaggi dal core (main thread).
@property (nonatomic, copy, nullable) void (^messageHandler)(NSString *message);
/// Chiamato (main thread) se il core chiede di chiudersi.
@property (nonatomic, copy, nullable) void (^shutdownHandler)(void);

@property (atomic, readonly) BOOL isRunning;
@property (atomic, readonly) BOOL isPaused;

- (void)startWithGamePath:(NSString *)path
             initialState:(nullable NSData *)state
                  saveRAM:(nullable NSData *)saveRAM
               completion:(void (^)(NSError * _Nullable error))completion;

- (void)pause;
- (void)resume;
/// Da chiamare quando il layer cambia dimensione.
- (void)layerDidResize;

- (void)captureStateWithCompletion:(void (^)(NSData * _Nullable state, NSData * _Nullable saveRAM))completion;
- (void)loadState:(NSData *)state completion:(void (^)(BOOL ok))completion;
- (void)resetGame;
/// Cattura stato + SRAM, poi spegne il core. Completion sul main thread.
- (void)stopWithCompletion:(void (^)(NSData * _Nullable state, NSData * _Nullable saveRAM))completion;

- (void)setButton:(ARCButton)button pressed:(BOOL)pressed source:(ARCInputSource)source;
/// x, y in -1...1 (y positivo = giù).
- (void)setAnalogStick:(NSInteger)stick x:(float)x y:(float)y source:(ARCInputSource)source;
- (void)clearInputForSource:(ARCInputSource)source;

/// YES se il processo ha il JIT attivo (es. abilitato con StikDebug).
+ (BOOL)isJITAvailable;

@end

NS_ASSUME_NONNULL_END
