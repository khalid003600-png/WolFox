#import "../../WolFox.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>



static IMP OriginalCommentNodeDidLoad;
static IMP OriginalCommentViewSetNode;
static IMP OriginalCommentUIViewDidMove;
static IMP OriginalCommentNodeSetFrame;
static const void *WolFoxStoredCommentAssociation = &WolFoxStoredCommentAssociation;
static const void *WolFoxCommentTextAssociation = &WolFoxCommentTextAssociation;
static const void *WolFoxCommentNodeAssociation = &WolFoxCommentNodeAssociation;
static const void *WolFoxCommentGestureAssociation = &WolFoxCommentGestureAssociation;

static id WolFoxObjectMessage(id receiver, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    return receiver != nil && [receiver respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(receiver, selector) : nil;
}

static NSString *WolFoxCleanCommentText(NSString *text) {
    if (![text isKindOfClass:NSString.class]) {
        return nil;
    }
    NSString *cleaned = [text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return cleaned.length == 0 ? nil : cleaned;
}

static BOOL WolFoxIsCommentToken(NSString *token) {
    NSString *lower = token.lowercaseString;
    return [lower containsString:@"comment"] ||
           [lower containsString:@"id_ui_comment_cell"];
}

static BOOL WolFoxIsCommentTextToken(NSString *token) {
    NSString *lower = token.lowercaseString;
    return [lower containsString:@"comment_content"] ||
           [lower containsString:@"comment_text"] ||
           [lower containsString:@"comment_body"];
}

static NSString *WolFoxCommentTextInNode(id node, NSUInteger depth) {
    if (node == nil || depth > 16) {
        return nil;
    }
    NSString *stored = WolFoxCleanCommentText(
        objc_getAssociatedObject(node, WolFoxCommentTextAssociation)
    );
    if (stored.length != 0) {
        return stored;
    }
    NSString *identifier = WolFoxObjectMessage(node, @"accessibilityIdentifier");
    NSString *description = [node description];
    id attributedText = WolFoxObjectMessage(node, @"attributedText");
    NSString *text = WolFoxCleanCommentText(
        WolFoxObjectMessage(attributedText, @"string")
    );
    if (text.length != 0 && WolFoxIsCommentTextToken(
        [NSString stringWithFormat:@"%@ %@", identifier ?: @"", description ?: @""])) {
        return text;
    }
    NSArray *children = WolFoxObjectMessage(node, @"subnodes");
    if (![children isKindOfClass:NSArray.class]) {
        children = WolFoxObjectMessage(node, @"children");
    }
    for (id child in children) {
        NSString *candidate = WolFoxCommentTextInNode(child, depth + 1);
        if (candidate.length != 0) {
            return candidate;
        }
    }
    return nil;
}

static NSString *WolFoxTextFromView(UIView *view) {
    if ([view isKindOfClass:UILabel.class]) {
        return WolFoxCleanCommentText(((UILabel *)view).text);
    }
    if ([view isKindOfClass:UITextView.class]) {
        return WolFoxCleanCommentText(((UITextView *)view).text);
    }
    NSString *label = WolFoxCleanCommentText(view.accessibilityLabel);
    return [view isKindOfClass:UIControl.class] ? nil : label;
}

static NSString *WolFoxCommentTextInView(UIView *view, BOOL exact,
                                         NSUInteger depth) {
    if (view == nil || depth > 16) {
        return nil;
    }
    NSString *stored = WolFoxCleanCommentText(
        objc_getAssociatedObject(view, WolFoxCommentTextAssociation)
    );
    if (stored.length != 0) {
        return stored;
    }
    NSString *token = [NSString stringWithFormat:@"%@ %@ %@",
        view.accessibilityIdentifier ?: @"",
        NSStringFromClass(view.class) ?: @"",
        [view description] ?: @""];
    NSString *ownText = WolFoxTextFromView(view);
    if (ownText.length != 0 && (!exact || WolFoxIsCommentTextToken(token))) {
        return ownText;
    }
    id node = objc_getAssociatedObject(view, WolFoxCommentNodeAssociation);
    if (node == nil) {
        node = WolFoxObjectMessage(view, @"keepalive_node");
    }
    NSString *nodeText = WolFoxCommentTextInNode(node, 0);
    if (nodeText.length != 0) {
        return nodeText;
    }
    NSString *best = nil;
    for (UIView *subview in view.subviews) {
        NSString *candidate = WolFoxCommentTextInView(subview, exact, depth + 1);
        if (candidate.length > best.length) {
            best = candidate;
        }
    }
    NSArray *elements = view.accessibilityElements;
    for (id element in elements) {
        NSString *identifier = WolFoxObjectMessage(element, @"accessibilityIdentifier");
        NSString *label = WolFoxCleanCommentText(
            WolFoxObjectMessage(element, @"accessibilityLabel")
        );
        if (label.length != 0 &&
            (!exact || WolFoxIsCommentTextToken(identifier ?: @"")) &&
            label.length > best.length) {
            best = label;
        }
    }
    return best;
}

static UIViewController *WolFoxControllerForView(UIView *view) {
    UIResponder *responder = view;
    while (responder != nil) {
        if ([responder isKindOfClass:UIViewController.class]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    UIViewController *controller = view.window.rootViewController;
    while (controller.presentedViewController != nil) {
        controller = controller.presentedViewController;
    }
    return controller;
}

static NSString *WolFoxStoredCommentForView(UIView *view) {
    for (UIView *candidate = view; candidate != nil;
         candidate = candidate.superview) {
        NSString *direct = objc_getAssociatedObject(
            candidate, WolFoxStoredCommentAssociation);
        if ([direct isKindOfClass:NSString.class] && direct.length != 0) {
            return direct;
        }
        id node = objc_getAssociatedObject(candidate, WolFoxCommentNodeAssociation);
        if (node == nil) node = WolFoxObjectMessage(candidate, @"keepalive_node");
        for (NSUInteger depth = 0; node != nil && depth < 14; depth++) {
            NSString *stored = objc_getAssociatedObject(
                node, WolFoxStoredCommentAssociation);
            if ([stored isKindOfClass:NSString.class] && stored.length != 0) {
                return stored;
            }
            node = WolFoxObjectMessage(node, @"supernode");
        }
    }
    return nil;
}

static NSString *WolFoxCommentTextForView(UIView *view) {
    NSString *stored = WolFoxStoredCommentForView(view);
    if (stored.length != 0) return stored;
    UIView *candidate = view;
    for (NSUInteger depth = 0; candidate != nil && depth < 8; depth++) {
        NSString *text = WolFoxCommentTextInView(candidate, YES, 0);
        if (text.length != 0) {
            return text;
        }
        candidate = candidate.superview;
    }
    return nil;
}

@interface WolFoxCopyCommentTarget : NSObject
+ (instancetype)sharedTarget;
- (void)handleCopyComment:(UILongPressGestureRecognizer *)gesture;
@end

@implementation WolFoxCopyCommentTarget
+ (instancetype)sharedTarget {
    static WolFoxCopyCommentTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [WolFoxCopyCommentTarget new]; });
    return target;
}

- (void)handleCopyComment:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan || !WolFoxMasterEnabled()) {
        return;
    }
    UIView *view = gesture.view;
    NSString *text = WolFoxCommentTextForView(view);
    if (text.length == 0) {
        return;
    }
    UIImpactFeedbackGenerator *feedback =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:nil
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:WolFoxLocalized(@"Copy Comment")
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            UIPasteboard.generalPasteboard.string = text;
            UINotificationFeedbackGenerator *confirmation =
                [UINotificationFeedbackGenerator new];
            [confirmation notificationOccurred:UINotificationFeedbackTypeSuccess];
        }]];
    [menu addAction:[UIAlertAction actionWithTitle:WolFoxLocalized(@"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = view;
    menu.popoverPresentationController.sourceRect = view.bounds;
    UIViewController *controller = WolFoxControllerForView(view);
    if (controller.presentedViewController == nil) {
        [controller presentViewController:menu animated:YES completion:nil];
    }
}
@end

static void WolFoxAttachCommentGesture(UIView *view, id node) {
    if (view == nil) {
        return;
    }
    if (node != nil) {
        objc_setAssociatedObject(view, WolFoxCommentNodeAssociation,
                                 node, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (objc_getAssociatedObject(view, WolFoxCommentGestureAssociation) != nil) {
        return;
    }
    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc]
        initWithTarget:WolFoxCopyCommentTarget.sharedTarget
                action:@selector(handleCopyComment:)];
    gesture.minimumPressDuration = 0.25;
    gesture.cancelsTouchesInView = NO;
    [view addGestureRecognizer:gesture];
    view.userInteractionEnabled = YES;
    objc_setAssociatedObject(view, WolFoxCommentGestureAssociation,
                             gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL WolFoxIsCommentContainer(id node) {
    NSString *description = [node description];
    return [description containsString:@"id.ui.comment_cell"] ||
           [description containsString:@"id.ui.comment_thread"] ||
           [description containsString:@"comment_reply"];
}

static NSString *WolFoxNodeIdentifier(id node) {
    NSString *identifier = WolFoxObjectMessage(node, @"accessibilityIdentifier");
    if ([identifier isKindOfClass:NSString.class] && identifier.length != 0) {
        return identifier;
    }
    @try {
        id value = [node valueForKey:@"_accessibilityIdentifier"];
        return [value isKindOfClass:NSString.class] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void WolFoxStoreCommentOnContainers(id node, NSString *text) {
    id supernodes = WolFoxObjectMessage(node, @"supernodes");
    NSArray *all = nil;
    if ([supernodes respondsToSelector:@selector(allObjects)]) {
        all = [supernodes allObjects];
    } else if ([supernodes isKindOfClass:NSArray.class]) {
        all = supernodes;
    }
    for (id container in all) {
        if (!WolFoxIsCommentContainer(container)) continue;
        objc_setAssociatedObject(container, WolFoxStoredCommentAssociation,
                                 text, OBJC_ASSOCIATION_COPY_NONATOMIC);
        UIView *rendered = WolFoxObjectMessage(container, @"view");
        if ([rendered isKindOfClass:UIView.class]) {
            objc_setAssociatedObject(rendered, WolFoxStoredCommentAssociation,
                                     text, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        return;
    }
}

static void WolFoxCommentNodeSetFrame(id receiver, SEL selector, CGRect frame) {
    if (OriginalCommentNodeSetFrame != NULL) {
        ((void (*)(id, SEL, CGRect))OriginalCommentNodeSetFrame)(receiver, selector,
                                                                 frame);
    }
    NSString *identifier = WolFoxNodeIdentifier(receiver);
    if (identifier.length == 0) return;
    if (![identifier isEqualToString:@"id.comment.content.label"]) return;
    id attributed = WolFoxObjectMessage(receiver, @"attributedText");
    NSString *text = WolFoxCleanCommentText(
        WolFoxObjectMessage(attributed, @"string"));
    if (text.length == 0) return;
    WolFoxStoreCommentOnContainers(receiver, text);
}

static void WolFoxCommentNodeDidLoad(id receiver, SEL selector) {
    if (OriginalCommentNodeDidLoad != NULL) {
        ((void (*)(id, SEL))OriginalCommentNodeDidLoad)(receiver, selector);
    }
    NSString *identifier = WolFoxObjectMessage(receiver, @"accessibilityIdentifier");
    NSString *token = [NSString stringWithFormat:@"%@ %@",
        identifier ?: @"", [receiver description] ?: @""];
    if (!WolFoxIsCommentTextToken(token)) {
        return;
    }
    id attributedText = WolFoxObjectMessage(receiver, @"attributedText");
    NSString *text = WolFoxCleanCommentText(
        WolFoxObjectMessage(attributedText, @"string")
    );
    if (text.length == 0) {
        return;
    }
    objc_setAssociatedObject(receiver, WolFoxCommentTextAssociation,
                             text, OBJC_ASSOCIATION_COPY_NONATOMIC);
    UIView *renderedView = WolFoxObjectMessage(receiver, @"view");
    if ([renderedView isKindOfClass:UIView.class]) {
        objc_setAssociatedObject(renderedView, WolFoxCommentTextAssociation,
                                 text, OBJC_ASSOCIATION_COPY_NONATOMIC);
        WolFoxAttachCommentGesture(renderedView, receiver);
    }
    id parent = WolFoxObjectMessage(receiver, @"yogaParent");
    for (NSUInteger depth = 0; parent != nil && depth < 16; depth++) {
        if (WolFoxIsCommentToken([parent description])) {
            objc_setAssociatedObject(parent, WolFoxCommentTextAssociation,
                                     text, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        parent = WolFoxObjectMessage(parent, @"yogaParent");
    }
}

static void WolFoxCommentViewSetNode(UIView *receiver, SEL selector, id node) {
    if (OriginalCommentViewSetNode != NULL) {
        ((void (*)(id, SEL, id))OriginalCommentViewSetNode)(receiver, selector, node);
    }
    WolFoxProfileConsiderDisplayView(receiver, node);
    NSString *token = [NSString stringWithFormat:@"%@ %@ %@",
        NSStringFromClass(receiver.class) ?: @"",
        [receiver description] ?: @"", [node description] ?: @""];
    NSString *text = WolFoxCommentTextInNode(node, 0);
    BOOL tokenMatch = WolFoxIsCommentToken(token);
    if (tokenMatch || text.length != 0) {
        WolFoxAttachCommentGesture(receiver, node);
    }
}

static void WolFoxCommentUIViewDidMove(UIView *receiver, SEL selector) {
    if (OriginalCommentUIViewDidMove != NULL) {
        ((void (*)(id, SEL))OriginalCommentUIViewDidMove)(receiver, selector);
    }
    NSString *token = [NSString stringWithFormat:@"%@ %@ %@",
        NSStringFromClass(receiver.class) ?: @"",
        receiver.accessibilityIdentifier ?: @"",
        [receiver description] ?: @""];
    if (WolFoxIsCommentToken(token)) {
        WolFoxAttachCommentGesture(receiver,
            WolFoxObjectMessage(receiver, @"keepalive_node"));
    }
}

void WolFoxInstallCopyCommentHooks(void) {
    WolFoxInstallInstanceHook(@"ASDisplayNode", @"didLoad",
        (IMP)WolFoxCommentNodeDidLoad, &OriginalCommentNodeDidLoad);
    WolFoxInstallInstanceHook(@"_ASDisplayView", @"setKeepalive_node:",
        (IMP)WolFoxCommentViewSetNode, &OriginalCommentViewSetNode);
    WolFoxInstallInstanceHook(@"UIView", @"didMoveToWindow",
        (IMP)WolFoxCommentUIViewDidMove, &OriginalCommentUIViewDidMove);
    WolFoxInstallInstanceHook(@"ASDisplayNode", @"setFrame:",
        (IMP)WolFoxCommentNodeSetFrame, &OriginalCommentNodeSetFrame);
}
