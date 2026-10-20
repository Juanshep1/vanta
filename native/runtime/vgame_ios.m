/* iOS glue for the Vanta game runtime. Since iOS 26 every app must use the scene lifecycle (UIScene); SDL2
 * predates that and opens a plain UIWindow, which iOS 27 stops on. So the app declares this scene delegate in
 * its Info.plist, and the SDL window is attached to the scene whichever of the two arrives first. */
#import <UIKit/UIKit.h>
#include <SDL.h>
#include <SDL_syswm.h>

static UIWindowScene *vg_scene = nil;
static UIWindow *vg_window = nil;

static void vg_join(void) {
    if (vg_scene && vg_window && vg_window.windowScene != vg_scene) {
        vg_window.windowScene = vg_scene;
        [vg_window makeKeyAndVisible];
    }
}

@interface VantaSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation VantaSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    vg_scene = (UIWindowScene *)scene;
    vg_join();
    self.window = vg_window;
}
@end

void vgame_ios_attach_window(SDL_Window *w) {
    SDL_SysWMinfo info;
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(w, &info)) return;
    vg_window = info.info.uikit.window;
    vg_join();
}
