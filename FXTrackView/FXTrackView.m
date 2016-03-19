//
//  FXTrackView.m
//  
//
//  Created by ShawnFoo on 12/4/15.
//  Copyright © 2015 ShawnFoo. All rights reserved.
//

#import "FXTrackView.h"
#import "FXTrackViewHeader.h"
#import "FXDeallocMonitor.h"
#import <pthread.h>

typedef NS_ENUM(NSUInteger, TrackViewStatus) {
    StatusNotStarted = 1001,
    StatusRunning,
    StatusPaused,
    StatusStoped
};

NSString const *FXDataTextKey = @"kFXDataText";
NSString const *FXTextCustomAttrsKey = @"kFXTextCustomAttrs";
NSString const *FXDataCustomViewKey = @"kFXDataCustomView";
NSString const *FXDataPriorityKey = @"kFXDataPriority";

@interface FXTrackView () {
    pthread_mutex_t _track_mutex;
    pthread_cond_t _track_prod, _track_cons;
    pthread_mutex_t _data_mutex;
    pthread_cond_t _data_prod, _data_cons;
    
    __block TrackViewStatus _status;
    __block BOOL _hasTracks;
    __block BOOL _hasData;
}

@property (assign, nonatomic) BOOL gotExactFrame;
@property (assign, nonatomic) NSInteger numOfTracks;
@property (assign, nonatomic) CGFloat trackHeight;

@property (strong, nonatomic) NSMutableArray *dataArr;
@property (strong, nonatomic) NSMutableArray *usersWordsArr;

@property (strong, nonatomic) dispatch_queue_t consumerQueue;
@property (strong, nonatomic) dispatch_queue_t trackProducerQueue;
@property (strong, nonatomic) dispatch_queue_t dataProducerQueue;
@property (strong, nonatomic) dispatch_queue_t computationQueue;

@property (strong, nonatomic) FXTextAttrs defaultAttrs;

// 按位判断某条弹道是否被占用
@property (assign, nonatomic) NSUInteger occupiedTrackBit;

@end

@implementation FXTrackView

#pragma mark - Lazy Loading Getter

- (dispatch_queue_t)consumerQueue {
    
    if (!_consumerQueue) {
        _consumerQueue = dispatch_queue_create("shawnfoo.trackView.consumerQueue", NULL);
    }
    return _consumerQueue;
}

- (dispatch_queue_t)trackProducerQueue {
    
    if (!_trackProducerQueue) {
        _trackProducerQueue = dispatch_queue_create("shawnfoo.trackView.trackProducerQueue", NULL);
    }
    return _trackProducerQueue;
}

- (dispatch_queue_t)dataProducerQueue {
    
    if (!_trackProducerQueue) {
        _trackProducerQueue = dispatch_queue_create("shawnfoo.trackView.dataProducerQueue", NULL);
    }
    return _trackProducerQueue;
}

- (dispatch_queue_t)computationQueue {
    
    if (!_computationQueue) {
        _computationQueue = dispatch_queue_create("shawnfoo.trackView.computationQueue", NULL);
    }
    return _computationQueue;
}

- (NSMutableArray *)usersWordsArr {
    
    if (!_usersWordsArr) {
        _usersWordsArr = [NSMutableArray arrayWithCapacity:15];
    }
    return _usersWordsArr;
}

- (NSMutableArray *)dataArr {

    if (!_dataArr) {
        _dataArr = [NSMutableArray arrayWithCapacity:15];
    }
    return _dataArr;
}

- (FXTextAttrs)defaultAttrs {
    
    if (!_defaultAttrs) {
        NSShadow *shadow = [[NSShadow alloc] init];
        shadow.shadowColor = FX_TextShadowColor;
        shadow.shadowOffset = FX_TextShadowOffset;
        
        _defaultAttrs = @{
                          NSFontAttributeName: [UIFont systemFontOfSize:FX_TextFontSize],
                          NSForegroundColorAttributeName: [UIColor whiteColor],
                          NSShadowAttributeName: shadow
                          };
    }
    
    return _defaultAttrs;
}

#pragma mark - LifeCycle

- (instancetype)initWithFrame:(CGRect)frame {
    
    if (self = [super initWithFrame:frame]) {
        [self commonSetup];
    }
    return self;
}

- (void)awakeFromNib {
    [super awakeFromNib];
    [self commonSetup];
}

- (void)commonSetup {
    
    _status = StatusNotStarted;
    self.clearTrackViewWhenPaused = YES;
    self.emptyDataWhenPaused = YES;
    
    pthread_mutex_init(&_track_mutex, NULL);
    pthread_cond_init(&_track_prod, NULL);
    pthread_cond_init(&_track_cons, NULL);
    
    pthread_mutex_init(&_data_mutex, NULL);
    pthread_cond_init(&_data_prod, NULL);
    pthread_cond_init(&_data_cons, NULL);
    
#ifdef FX_TrackViewBackgroundColor
    self.backgroundColor = FX_TrackViewBackgroundColor;
#else
    self.backgroundColor = [UIColor clearColor];
#endif
    [FXDeallocMonitor addMonitorToObj:self];
}

- (void)dealloc {
    
    pthread_mutex_destroy(&_track_mutex);
    pthread_mutex_destroy(&_data_mutex);
    pthread_cond_destroy(&_track_prod);
    pthread_cond_destroy(&_track_cons);
    pthread_cond_destroy(&_data_prod);
    pthread_cond_destroy(&_data_cons);
}

#pragma mark - Layout

- (void)layoutSubviews {
    [super layoutSubviews];
    
    if (!_gotExactFrame) {
        [self calcTracks];
    }
}

- (void)calcTracks {
    
    self.gotExactFrame = !CGSizeEqualToSize(self.frame.size, CGSizeZero);
    
    if (_gotExactFrame) {
        CGFloat height = self.frame.size.height;
        self.numOfTracks = floor(height / FX_EstimatedTrackHeight);
        self.trackHeight = height / _numOfTracks;
        _hasTracks = _numOfTracks > 0;
    }
    else {
        LogD(@"TrackView's size can't be zero!");
    }
}

#pragma mark - Actions

- (void)start {
    
    RunBlock_Safe_MainThread(^{
        _status = StatusRunning;
        if (!CGSizeEqualToSize(self.frame.size, CGSizeZero)) {
            dispatch_async(self.consumerQueue, ^{
                [self consumeData];
            });
        }
    });
}

- (void)pause {
    
    RunBlock_Safe_MainThread(^{
        _status = StatusPaused;
        [self stopConsuming];
        
        if (self.emptyDataWhenPaused) {
            pthread_mutex_lock(&_data_mutex);
            [_dataArr removeAllObjects];
            _hasData = NO;
            pthread_mutex_unlock(&_data_mutex);
        }
        if (self.hideViewWhenPaused) {
            self.hidden = YES;
        }
    });
}

- (void)resume {
    
    RunBlock_Safe_MainThread(^{
        _status = StatusRunning;
        [self start];
        
        if (self.hideViewWhenPaused) {
            self.hidden = NO;
        }
        if (self.clearTrackViewWhenPaused) {
            [self clearTrackView];
        }
    })
}

- (void)stop {
    
    RunBlock_Safe_MainThread(^{
        _status = StatusStoped;
        [self stopConsuming];
        [self clearTrackView];
    });
}

- (void)stopConsuming {
    
    // Break the waiting consumer thread! Otherwise, self can't be released. Memory leaks!
    if (!_hasTracks) {
        pthread_mutex_lock(&_track_mutex);
        _hasTracks = YES;
        pthread_cond_signal(&_track_cons);
        pthread_mutex_unlock(&_track_mutex);
    }
    if (!_hasData) {
        pthread_mutex_lock(&_data_mutex);
        _hasData = YES;
        pthread_cond_signal(&_data_cons);
        pthread_mutex_unlock(&_data_mutex);
    }
}

- (void)clearTrackView {
    
    for (UIView *subViews in self.subviews) {
        [subViews removeFromSuperview];
    }
}

#pragma mark - Data Producer & Consumer

- (void)addData:(FXData)data {
    
    if ([self shouldAcceptData]) {
        @WeakObj(self);
        dispatch_async(self.dataProducerQueue, ^{
            @StrongObj(self);
            pthread_mutex_lock(&_data_mutex);
            LogD(@"☀️_carrier_prod get lock");
            if ([self checkData:data]) {
                [self insertData:data];
                if (!_hasData) {
                    _hasData = YES;
                    pthread_cond_signal(&_data_cons);
                }
            }
            pthread_mutex_unlock(&_data_mutex);
        });
    }
}

- (void)addDataArr:(NSArray *)dataArr {
    
    if (0 == dataArr.count) { return; }
    if ([self shouldAcceptData]) {
        @WeakObj(self);
        dispatch_async(self.dataProducerQueue, ^{
            @StrongObj(self);
            pthread_mutex_lock(&_data_mutex);
            LogD(@"☀️_carrier_prod get lock");
            BOOL addedData = NO;
            for (FXData data in dataArr) {
                if ([self checkData:data]) {
                    [self insertData:data];
                    addedData = YES;
                }
            }
            if (!_hasData && addedData) {
                _hasData = YES;
                pthread_cond_signal(&_data_cons);
            }
            pthread_mutex_unlock(&_data_mutex);
        });
    }
}

- (FXData)fetchData {
    
    pthread_mutex_lock(&_data_mutex);
    LogD(@"☀️_data_cons get lock");
    while (!_hasData) {// no carriers, waiting for producer to signal to consumer
        LogD(@"☀️_data_cons waiting");
        pthread_cond_wait(&_data_cons, &_data_mutex);
    }
    FXData data = nil;
    if (StatusRunning == _status) {
        data = _dataArr.firstObject;
        [_dataArr removeObjectAtIndex:0];
        _hasData = _dataArr.count > 0;
    }
    pthread_mutex_unlock(&_data_mutex);
    return data;
}

- (void)insertData:(FXData)data {
    
    NSNumber *priority = data[FXDataPriorityKey];
    if (!priority || PriorityNormal == priority.unsignedIntegerValue) {
        [self.dataArr addObject:data];
    }
    else {
        [self.dataArr insertObject:data atIndex:0];
    }
}

- (BOOL)shouldAcceptData {
    
    BOOL isRunning = StatusRunning == _status;
    BOOL isPaused = StatusPaused == _status;
    
    return isRunning || (isPaused&&_acceptDataWhenPaused);
}

- (BOOL)checkData:(FXData)data {
    
    NSString *text = data[FXDataTextKey];
    
    if ([text isKindOfClass:[NSString class]] && text.length>0) {
        return true;
    }
    if ([data[FXTextCustomAttrsKey] isKindOfClass:[NSDictionary class]]) {
        return true;
    }
    //TODO: Add CustomView Support
    
    return false;
}

#pragma mark - Track Producer & Consumer

- (NSInteger)fetchUnoccupiedTrackIndex {
    
    pthread_mutex_lock(&_track_mutex);
    LogD(@"🌎_track_cons get lock");
    while (!_hasTracks) {
        LogD(@"🌎_track_cons waiting");
        pthread_cond_wait(&_track_cons, &_track_mutex);
    }
    
    NSInteger index = -1;
    if (StatusRunning == _status) {
        NSMutableArray *randomArr = nil;
        for (int i = 0; i < _numOfTracks; i++) {
            
            if ( 1<<i & _occupiedTrackBit) {
                continue;
            }
            if (!randomArr) {
                randomArr = [NSMutableArray arrayWithCapacity:_numOfTracks];
            }
            [randomArr addObject:@(i)];
        }
        NSUInteger count = randomArr.count;
        NSNumber *num = (count==1 ? randomArr[0] : randomArr[arc4random()%count]);
        index = num.intValue;
        [self setOccupiedTrackAtIndex:index];
        
        _hasTracks = count > 1 ? YES : NO;
    }
    
    pthread_mutex_unlock(&_track_mutex);
    return index;
}

- (void)setOccupiedTrackAtIndex:(NSInteger)index {
    
    if (index < self.numOfTracks) {
        self.occupiedTrackBit |= 1 << index;
    }
}

- (void)removeOccupiedTrackAtIndex:(NSInteger)index {
    
    pthread_mutex_lock(&_track_mutex);
    if (index < self.numOfTracks) {
        LogD(@"🌎_track_prod get lock");
        self.occupiedTrackBit -= 1 << index;
        if (!_hasTracks) {
            _hasTracks = YES;
            pthread_cond_signal(&_track_cons);
        }
    }
    pthread_mutex_unlock(&_track_mutex);
}

#pragma mark - Animation Computation

// 随机移动速度
- (NSUInteger)randomVelocity {
    
    return arc4random()%(FX_MaxVelocity-FX_MinVelocity) + FX_MinVelocity;
}

// 动画时间
- (CGFloat)animateDurationOfVelocity:(NSUInteger)velocity carrierWidth:(CGFloat)width {
    
    // 总的移动距离 = 背景View宽度 + 弹幕块本身宽度
    return (self.frame.size.width + width) / velocity;
}

// 重置弹道时间
- (CGFloat)resetTrackTimeOfVelocity:(NSUInteger)velocity carrierWidth:(CGFloat)width {
    
    // 重置距离 + 弹幕块本身长度  才是总的移动距离(判断的点为末尾的X坐标)
    return (self.frame.size.width*FX_ResetTrackOffsetRatio + width) / velocity;
}

// 弹幕块起始坐标
- (CGPoint)startPointWithIndex:(NSUInteger)index {
    
    return CGPointMake(self.frame.size.width, index * _trackHeight);
}

- (void)consumeData {
    
    while (StatusRunning == _status) {
        
        FXData data = [self fetchData];
        if (data) {
            NSInteger unoccupiedIndex = [self fetchUnoccupiedTrackIndex];
            if (unoccupiedIndex > -1) {
                dispatch_async(self.computationQueue, ^{
                    if (data[FXDataTextKey]) {
                        FXTextAttrs attrs = data[FXTextCustomAttrsKey] ?: nil;
                        if (!attrs) {
                            NSNumber *priority = data[FXDataPriorityKey];
                            if (PriorityNormal == priority.unsignedIntegerValue) {
                                attrs = self.normalPriorityTextAttrs;
                            }
                            else if (PriorityHigh == priority.unsignedIntegerValue) {
                                attrs = self.highPriorityTextAttrs;
                            }
                            attrs = attrs ?: self.defaultAttrs;
                        }
                        [self presentText:data[FXDataTextKey] attrs:attrs trackIndex:unoccupiedIndex];
                    }
                    else if (data[FXDataCustomViewKey]) {
                        [self presentCustomView:data[FXDataCustomViewKey] trackIndex:unoccupiedIndex];
                    }
                });
            }
        }
    }
}

- (void)presentText:(NSString *)text attrs:(FXTextAttrs)attrs trackIndex:(NSUInteger)index {
    
    CGSize size = [text sizeWithAttributes:attrs];
    CGPoint point = [self startPointWithIndex:index];
    NSUInteger velocity = [self randomVelocity];
    
    CGFloat animDuration = [self animateDurationOfVelocity:velocity carrierWidth:size.width];
    CGFloat resetTime = [self resetTrackTimeOfVelocity:velocity carrierWidth:size.width];
    
    NSAttributedString *attrText = [[NSAttributedString alloc] initWithString:text attributes:attrs];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(point.x, point.y, size.width, _trackHeight)];
        label.attributedText = attrText;
        [self addSubview:label];
        
        [UIView animateWithDuration:animDuration
                              delay:0
                            options:UIViewAnimationOptionCurveLinear
                         animations:
         ^{
             CGRect rect = label.frame;
             rect.origin.x = -rect.size.width;
             label.frame = rect;
             [label layoutIfNeeded];
         } completion:^(BOOL finished) {
             
             [label removeFromSuperview];
         }];
    });
    
    // reset track
    @WeakObj(self);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, resetTime * NSEC_PER_SEC), self.trackProducerQueue, ^(void){
        @StrongObj(self);
        [self removeOccupiedTrackAtIndex:index];
    });
}

- (void)presentCustomView:(UIView *)customView trackIndex:(NSUInteger)index {
    //TODO: Add support for customView
}

@end