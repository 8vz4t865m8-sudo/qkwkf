/**
 * T3网络验证 iOS 弹窗验证组件（弹窗版）
 * 官网: https://www.t3yanzheng.com
 *
 * 本示例演示「弹窗」模式：验证窗口以浮动对话框形式出现在应用界面上方
 * 与全屏验证页（ios 示例）不同，弹窗不会遮盖整个屏幕
 *
 * 依赖: UIKit + T3Verify SDK
 */

#import "T3VerifyDialog.h"

// 主题色
#define T3_COLOR_PRIMARY     [UIColor colorWithRed:0.42 green:0.39 blue:1.0 alpha:1.0]
#define T3_COLOR_PRIMARY_DK  [UIColor colorWithRed:0.35 green:0.32 blue:0.88 alpha:1.0]
#define T3_COLOR_BG          [UIColor colorWithRed:0.94 green:0.95 blue:0.96 alpha:1.0]
#define T3_COLOR_CARD        [UIColor whiteColor]
#define T3_COLOR_TEXT_PRI    [UIColor colorWithRed:0.10 green:0.10 blue:0.18 alpha:1.0]
#define T3_COLOR_TEXT_SEC    [UIColor colorWithRed:0.42 green:0.44 blue:0.50 alpha:1.0]
#define T3_COLOR_TEXT_HINT   [UIColor colorWithRed:0.61 green:0.64 blue:0.69 alpha:1.0]
#define T3_COLOR_SUCCESS     [UIColor colorWithRed:0.06 green:0.73 blue:0.51 alpha:1.0]
#define T3_COLOR_WARNING     [UIColor colorWithRed:0.96 green:0.62 blue:0.04 alpha:1.0]
#define T3_COLOR_ERROR       [UIColor colorWithRed:0.94 green:0.27 blue:0.27 alpha:1.0]
#define T3_COLOR_DIVIDER     [UIColor colorWithRed:0.90 green:0.91 blue:0.92 alpha:1.0]
#define T3_COLOR_INPUT_BG    [UIColor colorWithRed:0.98 green:0.98 blue:0.98 alpha:1.0]
#define T3_COLOR_INPUT_BDR   [UIColor colorWithRed:0.82 green:0.84 blue:0.86 alpha:1.0]
#define T3_COLOR_DIM         [UIColor colorWithWhite:0.0 alpha:0.4]


@interface T3VerifyDialog () <UITextFieldDelegate>
@property (nonatomic, strong) T3Verify *verify;
@property (nonatomic, copy) NSString *localVersion;
@property (nonatomic, strong) UIView *overlayView;
@property (nonatomic, strong) UIView *dialogCard;
@property (nonatomic, strong) UIViewController *hostVC;
// UI
@property (nonatomic, strong) UILabel *noticeContent;
@property (nonatomic, strong) UILabel *versionContent;
@property (nonatomic, strong) UILabel *versionBadge;
@property (nonatomic, strong) UITextField *kamiInput;
@property (nonatomic, strong) UIButton *loginButton;
@property (nonatomic, strong) UILabel *statusLabel;
@end


@implementation T3VerifyDialog

- (instancetype)initWithVerify:(T3Verify *)verify localVersion:(NSString *)localVersion {
    self = [super init];
    if (self) {
        _verify = verify;
        _localVersion = localVersion;
    }
    return self;
}

// ============================================================
// 展示弹窗（浮动在当前界面上方，非全屏）
// ============================================================

- (void)showInViewController:(UIViewController *)viewController {
    self.hostVC = viewController;
    UIView *rootView = viewController.view;

    // ---- 半透明遮罩层 ----
    self.overlayView = [[UIView alloc] initWithFrame:rootView.bounds];
    self.overlayView.backgroundColor = T3_COLOR_DIM;
    self.overlayView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.overlayView.alpha = 0;
    [rootView addSubview:self.overlayView];

    // ---- 弹窗卡片 ----
    CGFloat cardWidth = MIN(rootView.bounds.size.width * 0.88, 360);
    self.dialogCard = [[UIView alloc] init];
    self.dialogCard.backgroundColor = T3_COLOR_CARD;
    self.dialogCard.layer.cornerRadius = 16;
    self.dialogCard.layer.shadowColor = [UIColor colorWithWhite:0 alpha:0.15].CGColor;
    self.dialogCard.layer.shadowOffset = CGSizeMake(0, 8);
    self.dialogCard.layer.shadowRadius = 24;
    self.dialogCard.layer.shadowOpacity = 1.0;
    self.dialogCard.translatesAutoresizingMaskIntoConstraints = NO;
    [self.overlayView addSubview:self.dialogCard];

    [NSLayoutConstraint activateConstraints:@[
        [self.dialogCard.centerXAnchor constraintEqualToAnchor:self.overlayView.centerXAnchor],
        [self.dialogCard.centerYAnchor constraintEqualToAnchor:self.overlayView.centerYAnchor constant:-20],
        [self.dialogCard.widthAnchor constraintEqualToConstant:cardWidth]
    ]];

    CGFloat pad = 20;

    // ---- 标题行 ----
    UILabel *logo = [[UILabel alloc] init];
    logo.text = @"T3";
    logo.font = [UIFont boldSystemFontOfSize:14];
    logo.textColor = [UIColor whiteColor];
    logo.textAlignment = NSTextAlignmentCenter;
    logo.backgroundColor = T3_COLOR_PRIMARY;
    logo.layer.cornerRadius = 15;
    logo.clipsToBounds = YES;
    logo.translatesAutoresizingMaskIntoConstraints = NO;
    [self.dialogCard addSubview:logo];

    UILabel *title = [self label:@"T3 网络验证" font:[UIFont boldSystemFontOfSize:16] color:T3_COLOR_TEXT_PRI];
    [self.dialogCard addSubview:title];

    UILabel *subtitle = [self label:@"请输入卡密完成验证" font:[UIFont systemFontOfSize:11] color:T3_COLOR_TEXT_SEC];
    [self.dialogCard addSubview:subtitle];

    [NSLayoutConstraint activateConstraints:@[
        [logo.topAnchor constraintEqualToAnchor:self.dialogCard.topAnchor constant:pad],
        [logo.leadingAnchor constraintEqualToAnchor:self.dialogCard.leadingAnchor constant:pad],
        [logo.widthAnchor constraintEqualToConstant:30],
        [logo.heightAnchor constraintEqualToConstant:30],
        [title.leadingAnchor constraintEqualToAnchor:logo.trailingAnchor constant:10],
        [title.topAnchor constraintEqualToAnchor:logo.topAnchor constant:-1],
        [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:1]
    ]];

    // ---- 公告 ----
    UIView *noticeTitleRow = [self dotRow:T3_COLOR_WARNING text:@"公告"];
    [self.dialogCard addSubview:noticeTitleRow];
    [NSLayoutConstraint activateConstraints:@[
        [noticeTitleRow.topAnchor constraintEqualToAnchor:logo.bottomAnchor constant:16],
        [noticeTitleRow.leadingAnchor constraintEqualToAnchor:self.dialogCard.leadingAnchor constant:pad],
        [noticeTitleRow.trailingAnchor constraintEqualToAnchor:self.dialogCard.trailingAnchor constant:-pad]
    ]];

    self.noticeContent = [self label:@"正在加载..." font:[UIFont systemFontOfSize:12] color:T3_COLOR_TEXT_SEC];
    self.noticeContent.numberOfLines = 3;
    [self.dialogCard addSubview:self.noticeContent];
    [NSLayoutConstraint activateConstraints:@[
        [self.noticeContent.topAnchor constraintEqualToAnchor:noticeTitleRow.bottomAnchor constant:6],
        [self.noticeContent.leadingAnchor constraintEqualToAnchor:self.dialogCard.leadingAnchor constant:pad + 14],
        [self.noticeContent.trailingAnchor constraintEqualToAnchor:self.dialogCard.trailingAnchor constant:-pad]
    ]];

    // ---- 版本 ----
    UIView *verRow = [self dotRow:T3_COLOR_PRIMARY text:@"版本"];
    [self.dialogCard addSubview:verRow];
    [NSLayoutConstraint activateConstraints:@[
        [verRow.topAnchor constraintEqualToAnchor:self.noticeContent.bottomAnchor constant:12],
        [verRow.leadingAnchor constraintEqualToAnchor:self.dialogCard.leadingAnchor constant:pad],
        [verRow.trailingAnchor constraintEqualToAnchor:self.dialogCard.trailingAnchor constant:-pad]
    ]];

    self.versionContent = [self label:@"正在加载..." font:[UIFont systemFontOfSize:12] color:T3_COLOR_TEXT_SEC];
    [self.dialogCard addSubview:self.versionContent];
    [NSLayoutConstraint activateConstraints:@[
        [self.versionContent.topAnchor constraintEqualToAnchor:verRow.bottomAnchor constant:6],
        [self.versionContent.leadingAnchor constraintEqualToAnchor:self.dialogCard.leadingAnchor constant:pad + 14],
        [self.versionContent.trailingAnchor constraintEqualToAnchor:self.dialogCard.trailingAnchor constant:-pad]
    ]];

    self.versionBadge = [[UILabel alloc] init];
    self.versionBadge.font = [UIFont boldSystemFontOfSize:10];
    self.versionBadge.textColor = [UIColor whiteColor];
    self.versionBadge.textAlignment = NSTextAlignmentCenter;
    self.versionBadge.layer.cornerRadius = 8;
    self.versionBadge.clipsToBounds = YES;
    self.versionBadge.hidden = YES;
    self.versionBadge.translatesAutoresizingMaskIntoConstraints = NO;
    [self.dialogCard addSubview:self.versionBadge];
    [NSLayoutConstraint activateConstraints:@[
        [self.versionBadge.topAnchor constraintEqualToAnchor:self.versionContent.bottomAnchor constant:6],
        [self.versionBadge.leadingAnchor constraintEqualToAnchor:self.dialogCard.leadingAnchor constant:pad + 14],
        [self.versionBadge.heightAnchor constraintEqualToConstant:18],
        [self.versionBadge.widthAnchor constraintGreaterThanOrEqualToConstant:60]
    ]];

    // ---- 分割线 ----
    UIView *line = [[UIView alloc] init];
    line.backgroundColor = T3_COLOR_DIVIDER;
    line.translatesAutoresizingMaskIntoConstraints = NO;
    [self.dialogCard addSubview:line];
    [NSLayoutConstraint activateConstraints:@[
        [line.topAnchor constraintEqualToAnchor:self.versionBadge.bottomAnchor constant:14],
        [line.leadingAnchor constraintEqualToAnchor:self.dialogCard.leadingAnchor constant:pad],
        [line.trailingAnchor constraintEqualToAnchor:self.dialogCard.trailingAnchor constant:-pad],
        [line.heightAnchor constraintEqualToConstant:1]
    ]];

    // ---- 输入框 ----
    self.kamiInput = [[UITextField alloc] init];
    self.kamiInput.placeholder = @"请输入卡密";
    self.kamiInput.font = [UIFont systemFontOfSize:13];
    self.kamiInput.textColor = T3_COLOR_TEXT_PRI;
    self.kamiInput.backgroundColor = T3_COLOR_INPUT_BG;
    self.kamiInput.layer.cornerRadius = 8;
    self.kamiInput.layer.borderWidth = 1;
    self.kamiInput.layer.borderColor = T3_COLOR_INPUT_BDR.CGColor;
    self.kamiInput.autocorrectionType = UITextAutocorrectionTypeNo;
    self.kamiInput.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.kamiInput.returnKeyType = UIReturnKeyDone;
    self.kamiInput.delegate = self;
    self.kamiInput.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 0)];
    self.kamiInput.leftViewMode = UITextFieldViewModeAlways;
    self.kamiInput.translatesAutoresizingMaskIntoConstraints = NO;
    [self.dialogCard addSubview:self.kamiInput];
    [NSLayoutConstraint activateConstraints:@[
        [self.kamiInput.topAnchor constraintEqualToAnchor:line.bottomAnchor constant:14],
        [self.kamiInput.leadingAnchor constraintEqualToAnchor:self.dialogCard.leadingAnchor constant:pad],
        [self.kamiInput.trailingAnchor constraintEqualToAnchor:self.dialogCard.trailingAnchor constant:-pad],
        [self.kamiInput.heightAnchor constraintEqualToConstant:40]
    ]];

    // ---- 按钮 ----
    self.loginButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.loginButton setTitle:@"登  录" forState:UIControlStateNormal];
    self.loginButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [self.loginButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.loginButton.backgroundColor = T3_COLOR_PRIMARY;
    self.loginButton.layer.cornerRadius = 8;
    [self.loginButton addTarget:self action:@selector(onLoginTapped) forControlEvents:UIControlEventTouchUpInside];
    self.loginButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.dialogCard addSubview:self.loginButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.loginButton.topAnchor constraintEqualToAnchor:self.kamiInput.bottomAnchor constant:12],
        [self.loginButton.leadingAnchor constraintEqualToAnchor:self.dialogCard.leadingAnchor constant:pad],
        [self.loginButton.trailingAnchor constraintEqualToAnchor:self.dialogCard.trailingAnchor constant:-pad],
        [self.loginButton.heightAnchor constraintEqualToConstant:40]
    ]];

    // ---- 状态 ----
    self.statusLabel = [self label:@"" font:[UIFont systemFontOfSize:11] color:T3_COLOR_TEXT_SEC];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.hidden = YES;
    [self.dialogCard addSubview:self.statusLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.loginButton.bottomAnchor constant:8],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.dialogCard.leadingAnchor constant:pad],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.dialogCard.trailingAnchor constant:-pad],
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:self.dialogCard.bottomAnchor constant:-pad]
    ]];

    // ---- 弹入动画 ----
    self.dialogCard.transform = CGAffineTransformMakeScale(0.9, 0.9);
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.overlayView.alpha = 1;
        self.dialogCard.transform = CGAffineTransformIdentity;
    } completion:^(BOOL finished) {
        [self loadData];
    }];
}

// ============================================================
// 关闭弹窗
// ============================================================

- (void)dismiss {
    [UIView animateWithDuration:0.2 animations:^{
        self.overlayView.alpha = 0;
        self.dialogCard.transform = CGAffineTransformMakeScale(0.9, 0.9);
    } completion:^(BOOL finished) {
        [self.overlayView removeFromSuperview];
    }];
}

// ============================================================
// 数据加载
// ============================================================

- (void)loadData {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        T3NoticeResult *nr = [self.verify getNotice];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (nr.success) { self.noticeContent.text = nr.notice; }
            else { self.noticeContent.text = [NSString stringWithFormat:@"获取失败: %@", nr.error]; self.noticeContent.textColor = T3_COLOR_ERROR; }
        });

        T3VersionResult *vr = [self.verify getLatestVersion];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (vr.success) {
                self.versionContent.text = [NSString stringWithFormat:@"本地 %@  |  最新 %@", self.localVersion, vr.version];
                self.versionBadge.hidden = NO;
                if (vr.version && [vr.version compare:self.localVersion options:NSNumericSearch] == NSOrderedDescending) {
                    self.versionBadge.text = @"  有新版本  ";
                    self.versionBadge.backgroundColor = T3_COLOR_WARNING;
                } else {
                    self.versionBadge.text = @"  已是最新  ";
                    self.versionBadge.backgroundColor = T3_COLOR_SUCCESS;
                }
            } else {
                self.versionContent.text = [NSString stringWithFormat:@"获取失败: %@", vr.error];
                self.versionContent.textColor = T3_COLOR_ERROR;
            }
        });
    });
}

// ============================================================
// 登录
// ============================================================

- (void)onLoginTapped {
    NSString *kami = [self.kamiInput.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (kami.length == 0) {
        [self showToast:@"请输入卡密"];
        return;
    }
    [self.kamiInput resignFirstResponder];
    self.loginButton.enabled = NO;
    [self.loginButton setTitle:@"验证中..." forState:UIControlStateNormal];
    self.loginButton.backgroundColor = T3_COLOR_PRIMARY_DK;
    self.statusLabel.hidden = NO;
    self.statusLabel.text = @"正在连接服务器...";
    self.statusLabel.textColor = T3_COLOR_PRIMARY;

    NSString *mc = [T3Verify getMachineCode];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        T3LoginResult *r = [self.verify loginWithKami:kami imei:mc];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (r.success) {
                [self dismiss];
                if (self.onLoginSuccess) self.onLoginSuccess(r, kami, r.statecode);
            } else {
                self.loginButton.enabled = YES;
                [self.loginButton setTitle:@"登  录" forState:UIControlStateNormal];
                self.loginButton.backgroundColor = T3_COLOR_PRIMARY;
                self.statusLabel.text = r.error;
                self.statusLabel.textColor = T3_COLOR_ERROR;
            }
        });
    });
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self onLoginTapped]; return YES;
}

// ============================================================
// 工具
// ============================================================

- (UIView *)dotRow:(UIColor *)color text:(NSString *)text {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *dot = [[UIView alloc] init];
    dot.backgroundColor = color;
    dot.layer.cornerRadius = 3;
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:dot];
    UILabel *lbl = [self label:text font:[UIFont boldSystemFontOfSize:13] color:T3_COLOR_TEXT_PRI];
    [row addSubview:lbl];
    [NSLayoutConstraint activateConstraints:@[
        [dot.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [dot.centerYAnchor constraintEqualToAnchor:lbl.centerYAnchor],
        [dot.widthAnchor constraintEqualToConstant:6], [dot.heightAnchor constraintEqualToConstant:6],
        [lbl.leadingAnchor constraintEqualToAnchor:dot.trailingAnchor constant:6],
        [lbl.topAnchor constraintEqualToAnchor:row.topAnchor],
        [lbl.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [row.heightAnchor constraintEqualToConstant:18]
    ]];
    return row;
}

- (UILabel *)label:(NSString *)text font:(UIFont *)font color:(UIColor *)color {
    UILabel *l = [[UILabel alloc] init];
    l.text = text; l.font = font; l.textColor = color;
    l.numberOfLines = 0; l.translatesAutoresizingMaskIntoConstraints = NO;
    return l;
}

- (void)showToast:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:msg preferredStyle:UIAlertControllerStyleAlert];
    [self.hostVC presentViewController:a animated:YES completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [a dismissViewControllerAnimated:YES completion:nil];
    });
}

@end
