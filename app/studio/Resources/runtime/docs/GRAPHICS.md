# Graphics, games and apps in Vanta

Vanta can open a window and draw on it: shapes, text, images, sprite sheets and tile
maps, with keyboard, mouse, game-controller and touch input, sound effects and music.
That's enough for complete 2D games and for desktop apps like a calculator or a
to-do list. This page documents every function.

```
window(640, 400, "Hello")

let x be 0

to update(dt)
    change x to x + 120 * dt          # 120 units per second
    if x > 640
        change x to 0
    end
end

to draw()
    clear("#101018")
    circle(x, 200, 30, "orange")
    draw_text("Hello, canvas!", 20, 20, 16, "white")
end
```

```bash
vanta run hello.va          # builds it natively and opens the window
```

- [How it runs](#how-it-runs)
- [The window and the game loop](#the-window-and-the-game-loop)
- [Colours](#colours)
- [Shapes](#shapes)
- [Text and fonts](#text-and-fonts)
- [Images, sprite sheets and tile maps](#images-sprite-sheets-and-tile-maps)
- [Camera and clipping](#camera-and-clipping)
- [Keyboard](#keyboard)
- [Mouse and touch](#mouse-and-touch)
- [Game controllers](#game-controllers)
- [Sound](#sound)
- [Testing without a window](#testing-without-a-window-headless)
- [lib/game.va — game helpers](#libgameva--game-helpers)
- [lib/gui.va — buttons, sliders, text fields](#libguiva--buttons-sliders-text-fields)
- [The examples](#the-examples)
- [Moving programs between Vanta Studio and native](#moving-programs-between-vanta-studio-and-native)
- [The GBA mode](#the-gba-mode)

---

## How it runs

Canvas programs run as native programs. `vanta run game.va` (or `python3 vanta.py
game.va`) notices that the program draws, builds it with the native compiler
(`native/vantac.py`, which needs a C compiler and SDL2 — `brew install sdl2` on a Mac,
`apt install libsdl2-dev` on Linux) and runs it. It prints one line to say so. You can
also build it yourself:

```bash
vanta build game.va -o game && ./game
python3 native/vantac.py game.va --ios -o Game.app --name Game --bundle-id com.you.game   # iPhone/iPad
```

Everything is drawn into a framebuffer in memory and then scaled into the window, so a
program looks the same at any window size, on a high-DPI ("Retina") screen it is drawn
at 2x or 3x the pixels so shapes and TrueType text stay sharp, and it works with no
window at all for tests (see [headless](#testing-without-a-window-headless)).

**Coordinates** are canvas units: `window(640, 400)` gives x from 0 to 639 left to right
and y from 0 to 399 **top to bottom**. Positions and sizes can be decimals. Angles are
in degrees; 0 points right and angles turn clockwise (because y grows downward).

**Optional colour argument.** Every shape takes an optional colour as its last
argument; without it the shape uses the colour set by `color(...)`.

---

## The window and the game loop

### `window(width, height, [title], [options])`
Opens the window with a canvas of `width` x `height` units (calling it again resizes
it). If a program draws without calling `window`, a 480 x 360 window opens by itself.
The window can be resized, F11 (or Alt/Cmd+Enter) toggles full screen, and the canvas
is scaled to fit with black bars if the shapes differ.

`options` is a map:

| option | meaning |
|---|---|
| `"pixel_art": yes` | keep pixels square and sharp: no high-DPI, whole-number scaling, rotated images aren't smoothed |
| `"follow": yes` | the canvas is always the window's size (for apps: `screen_width()` changes when the window is resized) |
| `"scale": 2` | the starting window size as a multiple of the canvas (default: as big as fits comfortably) |
| `"fullscreen": yes` | start in full screen |
| `"resizable": no` | a fixed-size window |
| `"hidpi": no` | draw at 1x even on a high-DPI screen |

```
window(320, 180, "Tiny Quest", {"pixel_art": yes})
window(480, 600, "Notes", {"follow": yes})
```

### `canvas(width, height)`
The Vanta Studio name for `window(width, height)`.

### The game loop: `on_frame()`, or `update(dt)` and `draw()`
Write these functions and Vanta calls them **60 times a second** once the rest of your
program has run:

- `on_frame()` — do everything for one frame (the Vanta Studio style), or
- `update(dt)` — move things; `dt` is the seconds since the last frame (about 0.0167),
  and `draw()` — draw the frame. Either can be left out; `update()` may skip the `dt`.

A program with none of them keeps its picture on the screen until the window is closed.
The canvas is **not** cleared between frames — call `clear()` at the start of drawing
(or don't, to paint over the last frame like the paint example).

```
to on_frame()
    clear()
    circle(mouse_x(), mouse_y(), 10, "red")
end
```

### `run_game(on_frame)` / `run_game(update, draw)`
Starts the loop yourself with any functions (normally not needed: it's added for you).
It returns when the window closes or `stop_game()` is called.

```
to tick()
    clear()
    draw_text("frame {frame_count()}", 10, 10)
end
window(200, 100)
run_game(tick)
say "bye"
```

### `next_frame()`
For writing your own loop: shows what's been drawn, waits for the next 1/60 s, reads
input, and gives back `no` when the window has been closed.

```
window(300, 200)
let x be 0
while next_frame()
    clear()
    change x to (x + 2) % 300
    rect(x, 90, 20, 20, "lime")
end
```

### `stop_game()`
Ends the game loop after this frame (or makes `next_frame()` give back `no`).

### `frame_rate(fps)`
Changes how many frames per second the loop runs (default 60). `frame_rate(30)`
matches Vanta Studio.

### `fps()`
The frame rate actually achieved, as a whole number.

### `frame_count()`
How many frames have been shown since the window opened.

### `delta_time()`
The seconds the last frame took — the same `dt` that `update(dt)` gets.

### `game_time()`
Seconds since the window opened (a decimal). Handy for animation: `sin(game_time() * 3)`.

### `screen_width()`, `screen_height()`
The canvas size in units.

### `window_title(text)`
Changes the window's title.

### `fullscreen([on])`
Switches full screen on or off (`fullscreen()` toggles). Gives back whether it's on.

### `screenshot(path)`
Saves the canvas as an image file: `.png` (default), `.bmp`, `.jpg` or `.tga`.

```
if key_pressed("p")
    screenshot("shot.png")
end
```

### `touch_controls(on)`
Shows or hides the on-screen game pad on a touch screen (on by default on iPhone/iPad):
a D-pad that works like the **arrow keys**, and two buttons that work like **space** and
**enter**. So a keyboard game is playable on a phone with no changes. `VANTA_TOUCH=1`
shows the pad on a computer. The gui library turns it off for apps.

### `show_keyboard(on)`
Shows or hides the on-screen keyboard on a phone (text fields do this for you).

---

## Colours

A colour can be written as:

- a **name**: `"red"`, `"sky blue"`, `"darkgreen"` — the CSS colour names (spaces,
  `-` and `_` are ignored), plus `"transparent"`;
- **hex** text: `"#f80"`, `"#ff8800"`, or with transparency `"#ff880080"` (`#rgba` too);
- a list `[255, 136, 0]` or `[255, 136, 0, 128]`;
- a number `0xFF8800`.

**Alpha** (transparency) goes from 0 (invisible) to 255 (solid); a decimal between 0.0
and 1.0 also works (`0.5` is half).

### `color(colour)` / `color(red, green, blue, [alpha])`
Sets the colour shapes and text use when they aren't given one. The default is a light
lavender, `"#e7e3f5"`.

```
color("gold")
rect(10, 10, 50, 50)
color(255, 0, 0, 128)       # half-transparent red
```

### `clear([colour])`
Fills the canvas (or the clipping area) with a colour; default `"#0d0d17"`.

### `rgb(red, green, blue)`, `rgba(red, green, blue, alpha)`
Make a colour from numbers 0–255; gives back hex text like `"#ff8800"`.

```
let sky be rgb(90, 160, 255)
```

### `hsv(hue, saturation, value, [alpha])`
A colour from a hue (0–360 around the colour wheel) and saturation and brightness
(0–1). Great for rainbows: `hsv(frame_count() % 360, 0.8, 1)`.

### `mix_color(a, b, t)`
The colour `t` of the way from `a` to `b` (`0` = a, `1` = b). Good for gradients and fades.

```
for each i in range(0, 20)
    rect(0, i * 20, 640, 20, mix_color("navy", "skyblue", i / 19))
end
```

### `with_alpha(colour, alpha)`
The same colour with a different transparency: `with_alpha("red", 0.3)`.

### `line_width(width)`
How thick lines and outlines are, in units (default 1).

### `antialias(on)`
Smooth (antialiased) edges on circles, lines and polygons — on by default.
`antialias(no)` gives hard pixel edges for pixel-art games.

---

## Shapes

All shapes take an optional colour as the last argument.

### `rect(x, y, width, height, [colour])`
A filled rectangle with its top-left corner at x, y. (`fill_rect` is the same.)

### `outline_rect(x, y, width, height, [colour])`
Just the edge of a rectangle, `line_width()` thick, drawn inside the box.

### `round_rect(x, y, width, height, radius, [colour])`
A filled rectangle with rounded corners.

### `outline_round_rect(x, y, width, height, radius, [colour])`
The edge of a rounded rectangle.

```
round_rect(20, 20, 160, 48, 12, "#5b4cf0")
line_width(2)
outline_round_rect(20, 20, 160, 48, 12, "white")
```

### `circle(x, y, radius, [colour])`, `outline_circle(x, y, radius, [colour])`
A circle centred on x, y.

### `ellipse(x, y, radius_x, radius_y, [colour])`, `outline_ellipse(...)`
An oval centred on x, y.

### `line(x1, y1, x2, y2, [colour])`
A straight line, `line_width()` thick with round ends. Straight horizontal and vertical
lines snap to whole pixels so they stay crisp.

### `polyline(points, [colour])`
Lines joining a list of points (not closed). Points are `[[x, y], [x, y], ...]` or a
flat list `[x1, y1, x2, y2, ...]`.

### `triangle(x1, y1, x2, y2, x3, y3, [colour])`, `outline_triangle(...)`
A triangle through three corners.

### `polygon(points, [colour])`, `outline_polygon(points, [colour])`
A filled (or outlined) shape through a list of points.

```
polygon([[100, 20], [140, 100], [60, 100]], "lime")
```

### `arc(x, y, radius, start_angle, end_angle, [colour])`
Part of a circle's edge, from one angle to another (degrees, 0 = right, clockwise).

### `pie(x, y, radius, start_angle, end_angle, [colour])`
A filled slice of a circle (pie charts, a chomping mouth).

```
pie(100, 100, 40, 30, 330, "yellow")
```

### `pixel(x, y, [colour])`
One unit-sized dot.

### `get_pixel(x, y)`
The colour at a point of the canvas (or of the image being drawn into), as hex text.

---

## Text and fonts

The built-in font is an 8 x 8 pixel font (ASCII), drawn in whole-pixel steps: sizes 8,
16, 24, 32... (other sizes round to the nearest step). TrueType fonts (`.ttf`, `.ttc`)
can be any size and support any Unicode character the font has.

### `draw_text(text, x, y, [size], [colour])`
Draws text with its **top-left corner** at x, y. `size` is the text height in units
(default 16). Text can have several lines (`"\n"`). Any value is shown as text.

```
draw_text("Score: {score}", 10, 10, 16, "white")
```

### `text_at(x, y, text, [size])`
The Vanta Studio way: x, y is the start of the **baseline** (the line the letters sit
on). Uses the `color(...)` colour, or a colour given as a fifth argument.

### `text_width(text, [size])`, `text_height([size])` / `text_height(text, size)`
How wide and tall text will be, for centring and layout.

```
let w be text_width("GAME OVER", 32)
draw_text("GAME OVER", (screen_width() - w) / 2, 150, 32)
```

### `text_align(how)`
`"left"` (default), `"center"` or `"right"`: where x is for `draw_text` and `text_at`.

```
text_align("center")
draw_text("PAUSED", screen_width() / 2, 100, 24)
text_align("left")
```

### `load_font(path)`
Loads a TrueType font file and gives back a font. The names `"sans"`, `"bold"`,
`"serif"` and `"mono"` find a system font (Arial/Helvetica, Georgia, Courier/Menlo on a
Mac; DejaVu on Linux; Segoe/Arial on Windows) and give back `nothing` if there isn't
one, so you can fall back to the pixel font.

### `font(which)`
Chooses the font for `draw_text`/`text_at`: a font from `load_font`, a name like
`"sans"` (loaded once), or `nothing` for the built-in pixel font. Gives back whether it
worked.

```
font("sans")
draw_text("Smooth text", 20, 20, 22)
font(nothing)
draw_text("PIXEL TEXT", 20, 60, 16)
```

---

## Images, sprite sheets and tile maps

Images are pictures in memory. `load_image` reads PNG, JPG, BMP, GIF and TGA files.
Image values are handles (numbers) you pass to the image functions.

### `load_image(path)`
Loads an image file.

### `make_image(width, height, [colour])`
A new blank image (transparent unless you give a colour) to draw into.

### `image_from_rows(rows, palette)`
Makes pixel art from text: each character is one pixel, looked up in `palette` (a map
from single characters to colours). Characters not in the palette are transparent.
`rows` is a list of texts or one multi-line `"""` text (lines are trimmed; blank lines
skipped).

```
let heart be image_from_rows("""
    .RR.RR.
    RRRRRRR
    RRRRRRR
    .RRRRR.
    ..RRR..
    ...R...
""", {"R": "#ff3355"})
draw_image(heart, 100, 100, {"scale": 6})
```

### `image_width(image)`, `image_height(image)`
The size of an image.

### `draw_image(image, x, y, [options])`
Draws an image with its top-left corner at x, y. `options` is a map (or just a number,
meaning the scale):

| option | meaning |
|---|---|
| `"scale": 2` | bigger or smaller; `"scale_x"`, `"scale_y"` separately |
| `"width": 64`, `"height": 64` | draw it this size (give one to keep its shape) |
| `"rotation": 45` | turn it (degrees, clockwise) around its centre |
| `"origin_x"`, `"origin_y"` | turn around this point instead (in image pixels) |
| `"center": yes` | x, y is the image's centre (or origin point) instead of its corner |
| `"flip_x": yes`, `"flip_y": yes` | mirror it |
| `"alpha": 0.5` | transparency (0–1 or 0–255) |
| `"tint": "red"` | multiply its colours (white = unchanged) |
| `"region": [x, y, w, h]` | draw only part of the image |
| `"smooth": yes/no` | smooth (bilinear) or blocky pixels when rotated; smooth by default unless the window is `pixel_art` |

```
draw_image(ship, x, y, {"rotation": angle, "center": yes})
draw_image(player, px, py, {"flip_x": facing < 0, "scale": 3})
```

### `sprite_sheet(image, frame_width, frame_height)`
Says the image is a grid of equal frames (numbered from 0, left to right, then row by
row). Gives back the image.

### `frames_in(image)`
How many frames the sheet has.

### `draw_frame(image, frame, x, y, [options])`
Draws one frame of a sprite sheet (same options as `draw_image`). Frame numbers wrap
around, so `draw_frame(sheet, frame_count() / 6, x, y)` animates.

```
let walker be sprite_sheet(load_image("walk.png"), 32, 32)
draw_frame(walker, floor(game_time() * 8), 100, 100)
```

### `draw_tilemap(image, grid, x, y, [scale])`
Draws a whole level of tiles from a sprite sheet: `grid` is a list of rows, each a list
of frame numbers (`-1` or `nothing` = empty). Rows can also be text, where each
character is a tile: `0`–`9`, then `a`–`z` (10–35), `A`–`Z` (36–61), anything else empty
— and the grid can be one multi-line text. Only the visible tiles are drawn, so big
levels are cheap.

```
sprite_sheet(tiles, 16, 16)
draw_tilemap(tiles, """
    ..........
    ....22....
    0000000000
    1111111111
""", 0, 0)
```

### `draw_to(image)`, `draw_to_screen()`
Sends all drawing into an image instead of the canvas (render to texture), then back.
Good for building a picture once and drawing it many times, or for a paint program's
painting.

```
let badge be make_image(64, 64)
draw_to(badge)
circle(32, 32, 30, "gold")
draw_to_screen()
```

### `copy_screen()`
A new image with what's on the canvas now.

### `copy_image(image)`
A copy of an image.

### `save_image(image, path)`
Saves an image as `.png`, `.bmp`, `.jpg` or `.tga`.

### `image_pixel(image, x, y)`, `set_image_pixel(image, x, y, colour)`
Read or change one pixel of an image (hex text; `nothing` outside the image).

### `free_image(image)`
Frees an image's memory when you're done with it.

---

## Camera and clipping

### `camera(x, y, [zoom])`
Moves the view: the world point x, y appears at the top-left corner, and `zoom` makes
everything bigger (2) or smaller (0.5). It affects everything drawn afterwards.

### `camera_center(x, y, [zoom])`
The same, but the world point x, y appears in the middle of the canvas — the usual way
to follow a player.

### `no_camera()`
Back to the plain canvas: draw the score and other HUD after this.

```
to draw()
    clear("skyblue")
    camera_center(player_x, player_y, 2)
    draw_tilemap(tiles, level, 0, 0)
    circle(player_x, player_y, 6, "red")
    no_camera()
    draw_text("Coins: {coins}", 10, 10)
end
```

### `mouse_world_x()`, `mouse_world_y()`
Where the mouse is in the world, taking the camera into account.

### `clip(x, y, width, height)`, `no_clip()`
Only draws inside a rectangle until `no_clip()` (scrolling lists, panels).

---

## Keyboard

Keys have names: `"a"`–`"z"`, `"0"`–`"9"`, `"left"`, `"right"`, `"up"`, `"down"`,
`"space"`, `"enter"`, `"escape"`, `"tab"`, `"backspace"`, `"delete"`, `"shift"`,
`"ctrl"`, `"alt"`, `"cmd"`, `"home"`, `"end"`, `"pageup"`, `"pagedown"`, `"f1"`–`"f12"`,
`"-"`, `"="`, `","`, `"."`, `"/"`, `";"`, `"'"`, `"["`, `"]"`, `"kp0"`–`"kp9"` (number pad)
and the other names SDL knows.

### `key_down(key)`
Is the key held right now? Use it for smooth movement.

### `key_pressed(key)`
Was it pressed **this frame**? Use it for things that should happen once per press:
jumping, shooting, menus.

### `key_released(key)`
Was it let go this frame?

### `key_repeated(key)`
Pressed this frame, or repeating because it's held (like a text editor's Backspace).

### `last_key()`
The name of the last key pressed this frame, or `""`.

### `text_input()`
The text typed this frame (with the keyboard layout, Shift and accents applied) — for
text fields. `""` if nothing.

```
to update(dt)
    if key_down("left")
        change x to x - 200 * dt
    end
    if key_pressed("space")
        jump()
    end
    change name to name + text_input()
end
```

> In the interpreter, `key_down`, `key_up` and `key_pressed` are the 4.9 desktop-automation
> builtins (they press keys in *other* programs). In a canvas program they read the
> game's own keyboard as described here.

---

## Mouse and touch

Buttons are `"left"` (the default), `"right"` and `"middle"`. Positions are canvas
units. On a touch screen a finger also works as the left mouse button.

### `mouse_x()`, `mouse_y()`
Where the mouse is.

### `mouse_down([button])`
Is the button held?

### `mouse_pressed([button])`, `mouse_released([button])`
Was it pressed / let go this frame?

### `mouse_wheel()`
How far the wheel scrolled this frame (positive = up/away), a decimal.

### `show_mouse(on)`
Shows or hides the mouse pointer over the window.

### `touch_count()`
How many fingers are on the screen.

### `touch_x([n])`, `touch_y([n])`
Where finger `n` is (1 = the first finger, the default); `nothing` if there's no such finger.

### `touches()`
All fingers as `[[x, y], ...]`.

```
for each t in touches()
    circle(t[0], t[1], 30, "#ffffff60")
end
```

---

## Game controllers

Any controller SDL knows (Xbox, PlayStation, Switch Pro, MFi...). Players are numbered
1–4 (default 1). Buttons: `"a"`, `"b"`, `"x"`, `"y"`, `"start"`, `"back"`/`"select"`,
`"guide"`/`"home"`, `"lb"`, `"rb"` (shoulders), `"l3"`, `"r3"` (stick clicks), `"up"`,
`"down"`, `"left"`, `"right"` (D-pad). Axes: `"left_x"`, `"left_y"`, `"right_x"`,
`"right_y"` (-1 to 1) and `"lt"`, `"rt"` (triggers, 0 to 1).

### `pad_count()`
How many controllers are connected.

### `pad_down(button, [player])`, `pad_pressed(button, [player])`, `pad_released(button, [player])`
Like the key functions.

### `pad_axis(axis, [player])`
A stick or trigger position, with a small dead zone so a resting stick reads 0.

```
change x to x + pad_axis("left_x") * 200 * dt
if pad_pressed("a") or key_pressed("space")
    jump()
end
```

---

## Sound

Sounds play mixed together (up to 32 at once) at 44.1 kHz stereo. Sound values are
handles you pass to the sound functions.

### `load_sound(path)`
Loads a `.wav` or `.ogg` file.

### `play_sound(sound, [volume], [pan], [pitch], [loop])`
Plays a sound and gives back a *voice* number. `volume` 0–1 (default 1, up to 4 is
allowed), `pan` -1 (left) to 1 (right), `pitch` 1 = normal, 2 = an octave up (and
twice as fast), `loop` yes to repeat.

```
let coin be load_sound("coin.wav")
play_sound(coin, 0.8, 0, random_between(0.9, 1.1))
```

### `stop_sound(voice)`, `sound_playing(voice)`, `stop_all_sounds()`
Stop one voice / is it still playing / stop everything.

### `play_music(sound_or_path, [volume])`
Plays a sound on repeat as the background music (replacing any music playing).

### `stop_music()`, `music_volume(volume)`, `master_volume(volume)`
Stop the music, set its volume, set the volume of everything.

### `sound_length(sound)`
How long a sound is, in seconds.

### `make_tone(frequency, seconds, [wave], [volume])`
Makes a sound from a note: frequency in Hz (440 = the A above middle C), `wave` one of
`"sine"` (default), `"square"`, `"triangle"`, `"saw"`, `"noise"`, volume 0–1 (default 0.5).

### `beep([frequency], [seconds], [wave], [volume])`
Plays a tone straight away — instant retro sound effects with no files (defaults: 880 Hz,
0.1 s, square, 0.4). The same beep is made once and reused.

```
beep(660, 0.05)               # a blip
beep(110, 0.4, "saw")         # an explosion-ish buzz
beep(200, 0.3, "noise")       # a crash
```

### `make_sound(samples, [rate])`
Makes a sound from a list of numbers between -1 and 1 (default 44100 per second) — for
experimenting with synthesis.

```
let s be []
for each i in range(0, 22050)
    add sin(i * 2 * pi * 440 / 44100) * 0.3 to s
end
play_sound(make_sound(s))
```

---

## Testing without a window (headless)

Set `VANTA_HEADLESS=1` and a canvas program never opens a window or a sound device;
everything else behaves the same (the loop runs as fast as it can with `dt` fixed at
1/60 s). These environment variables drive and record it:

| variable | meaning |
|---|---|
| `VANTA_HEADLESS=1` | no window, no sound device |
| `VANTA_FRAMES=N` | stop after N frames (headless default: 600, i.e. 10 seconds of game time) |
| `VANTA_SHOT=path.png` | save a screenshot when the program ends |
| `VANTA_SHOT_FRAME=N` | ...at frame N instead; `30,60,90` saves several, numbering `%d` in the path (or adding `_0030`) |
| `VANTA_SHOT_EVERY=N` | save one every N frames (numbered) |
| `VANTA_INPUT=script` | scripted input (below); `@file.txt` reads the script from a file |
| `VANTA_SOUND_DUMP=out.wav` | write everything the mixer plays to a WAV file (no device used) |
| `VANTA_DENSITY=2` | headless high-DPI: draw at 2x like a Retina screen |
| `VANTA_TOUCH=1` | show the on-screen game pad on a computer |

**Input scripts** are steps separated by `;` or new lines, each starting with the frame
number it happens on (frames count from 0 when the window opens):

| step | does |
|---|---|
| `10 down space` / `20 up space` | hold / let go of a key |
| `10 press enter` | press for one frame (down on 10, up on 11) |
| `10 type hello world` | type text (for `text_input()`) |
| `10 move 100 200` | move the mouse |
| `10 click 100 200 [right]` | move there and click (down on 10, up on 11) |
| `10 mousedown [x y]` / `20 mouseup` | hold / let go of the left button |
| `10 wheel -3` | scroll |
| `10 pad_down a` / `pad_up a` / `pad_press a` | controller buttons (player 1) |
| `10 axis left_x 1.0` | a controller stick |
| `10 touch 50 60` / `20 untouch` | a finger |
| `10 shot path.png` | take a screenshot after frame 10 is drawn |
| `10 quit` | close the window |

```bash
VANTA_HEADLESS=1 VANTA_FRAMES=120 VANTA_SHOT=pong.png \
  VANTA_INPUT="10 press space; 20 down w; 60 up w" ./pong
```

### `test_input(script)`
Adds input steps from inside the program, in the same format. Steps without a frame
number happen at the start of the next frame — good for tests written in Vanta:

```
window(100, 100)
test_input("down space")
next_frame()
assert(key_pressed("space"), "space should be pressed")
```

`tools/canvas_headless.py` runs every example this way (and checks the API pixel by
pixel with `tests/canvas/api_check.va`); it's part of `python3 run_tests.py`.

---

## lib/game.va — game helpers

`import "game"` — written in Vanta, so you can read and change it.

### Vectors
| | |
|---|---|
| `vec(x, y)` | a vector (a `Vec` with `.x` and `.y`) |
| `vec_from_angle(degrees, [length])` | a vector pointing at an angle |
| `v.added(w)`, `v.subtracted(w)`, `v.scaled(k)` | arithmetic, giving back new vectors |
| `v.length()`, `v.normalized()`, `v.dot(w)` | length, the same direction with length 1, dot product |
| `v.distance_to(w)`, `v.angle()`, `v.rotated(degrees)` | distance, direction in degrees, turned |

```
let velocity be vec_from_angle(30, 200)
change pos to pos.added(velocity.scaled(dt))
```

### Rectangles and collisions
| | |
|---|---|
| `new Rect(x, y, w, h)` | a rectangle: `.right()`, `.bottom()`, `.center_x()`, `.center_y()`, `.has_point(px, py)`, `.overlaps(other)`, `.draw([colour])` |
| `overlap(x1, y1, w1, h1, x2, y2, w2, h2)` | do two boxes overlap? |
| `rects_overlap(a, b)` | the same for anything with x, y, w, h (a Rect, a Body, your own type) |
| `point_in_rect(px, py, x, y, w, h)` | is a point inside a box? |
| `circles_overlap(x1, y1, r1, x2, y2, r2)` | do two circles touch? |
| `circle_rect_overlap(cx, cy, r, x, y, w, h)` | does a circle touch a box? |
| `hit_side(a, b)` | which side of `b` box `a` hit: `"left"`, `"right"`, `"top"`, `"bottom"` or `nothing` — for bouncing |
| `distance(x1, y1, x2, y2)`, `angle_to(x1, y1, x2, y2)` | how far, which way (degrees) |

### Physics
`new Body(x, y, w, h)` is a moving box with `.vx`, `.vy` (velocity, units per second):

| | |
|---|---|
| `b.apply_gravity(gravity, dt, [max_fall])` | speed up downward |
| `b.move(dt)` | move by the velocity |
| `b.move_and_collide(solids, dt)` | move, stopping at any solid in the list (things with x, y, w, h); sets `.on_ground`, `.hit_wall`, `.hit_ceiling` |
| `b.center_x()`, `b.center_y()` | its middle |

```
player.apply_gravity(1500, dt)
player.move_and_collide(walls, dt)
if player.on_ground and key_pressed("space")
    change player.vy to -450
end
```

### Moving numbers and easing
| | |
|---|---|
| `lerp(a, b, t)` | the number `t` of the way from a to b |
| `approach(value, target, step)` | move toward target by at most step |
| `wrap(value, low, high)` | wrap around (leave one side, come back the other) |
| `smooth_follow(current, target, speed, dt)` | glide toward a target (cameras) |
| `ease_linear`, `ease_in`, `ease_out`, `ease_in_out`, `ease_out_back`, `ease_out_bounce` | easing curves for `t` from 0 to 1 |
| `tween(from, to, seconds, [easing])` | a `Tween`: `.update(dt)`, `.value()`, `.done()`, `.progress()`, `.restart()` |

```
let slide be tween(-200, 100, 0.8, ease_out_back)
# in update: slide.update(dt)      in draw: rect(slide.value(), 50, 100, 40)
```

### Timers and animation
| | |
|---|---|
| `timer(seconds, [repeating])` | a `Timer`: `.tick(dt)` gives back yes when it goes off; `.reset()`, `.progress()` |
| `animation(frames, [fps], [looping])` | an `Animation` over a list of frame numbers (or a count): `.update(dt)`, `.frame()`, `.done()`, `.restart()` |

```
let walk be animation([0, 1, 2, 1], 10)
# update: walk.update(dt)      draw: draw_frame(sheet, walk.frame(), x, y)
```

### Scenes
| | |
|---|---|
| `add_scene(name, update_fn, draw_fn)` | register a screen (title, game, game over...); the first one added starts |
| `go_to_scene(name)` | switch screens |
| `scene_name()`, `scene_time()` | the current screen and seconds since it started |
| `update_scene(dt)`, `draw_scene()` | call these from `update(dt)` and `draw()` |

```
add_scene("title", title_update, title_draw)
add_scene("play", play_update, play_draw)
to update(dt)
    update_scene(dt)
end
to draw()
    draw_scene()
end
```

### Random helpers and particles
| | |
|---|---|
| `random_between(low, high)` | a decimal |
| `random_chance(p)` | yes with probability p |
| `random_sign()` | -1 or 1 |
| `random_color()` | a bright colour |
| `particles([gravity])` | a `Particles`: `.burst(x, y, count, colour, [speed], [life])`, `.update(dt)`, `.draw()`, `.count()` |

```
let fx be particles()
fx.burst(x, y, 30, "orange")      # an explosion
```

---

## lib/gui.va — buttons, sliders, text fields

`import "gui"` gives immediate-mode widgets: you call them every frame from
`on_frame()` (or `draw()`), and they draw themselves and tell you what happened. Each
takes its place as `x, y, width, height`, or as one **cell** from the layout helpers.
A widget's label is its identity, so labels must be unique on screen; to show the same
text twice, add `##` and something unique: `button("Delete##3", ...)` shows "Delete".
The gui uses the system sans font when there is one.

| widget | gives back |
|---|---|
| `button(label, x, y, [w], [h])` | yes on the frame it's clicked |
| `accent_button(label, x, y, [w], [h])` | the same, in the accent colour |
| `label(text, x, y, [size], [colour])` or `label(text, cell, [size], [colour])` | — |
| `checkbox(label, checked, x, y)` | the new yes/no |
| `slider(id, value, low, high, x, y, [w], [h])` | the new value (whole numbers for whole-number ranges of 10 or more) |
| `text_field(id, text, x, y, [w], [h], [hint])` or `text_field(id, text, cell, [hint])` | the new text; click to type, Enter finishes |
| `submitted(id)` | was Enter pressed in that text field this frame? |
| `focus(id)` | put the typing cursor in a text field |
| `list_box(id, items, selected, x, y, [w], [h])` | the picked index (scrolls with the wheel) |
| `progress_bar(fraction, x, y, [w], [h])` | — |
| `panel(title, x, y, w, h)` | a window-like box; gives back its inside as a cell |
| `separator(x, y, w)` | — |
| `gui_background()` | clears to the theme's background |

**Layout:** `layout(x, y, width, [gap])` starts a column; `row(height, [columns])`
starts the next row, split into equal columns; `cell([span])` gives the next
`[x, y, w, h]` (spanning columns if asked); `space(units)` adds a gap.

**Look:** `gui_theme("dark")` (default) or `gui_theme("light")`; `gui_color(name)` gives
a theme colour (`"bg"`, `"panel"`, `"widget"`, `"accent"`, `"text"`, `"dim"`,
`"border"`, ...); `gui_text_size(size)` (default 16).

```
import "gui"
window(360, 240, "Settings", {"follow": yes})
let volume be 50
let muted be no
let name be ""

to on_frame()
    gui_background()
    layout(20, 20, 320)
    row(30)
    label("Settings", cell(), 24)
    row(36)
    change name to text_field("name", name, cell(), "Your name")
    row(30)
    change volume to slider("volume", volume, 0, 100, cell())
    row(30)
    change muted to checkbox("Muted", muted, cell())
    row(40, 2)
    if accent_button("Save", cell())
        say "saved {name} {volume} {muted}"
    end
    if button("Quit", cell())
        stop_game()
    end
end
```

---

## The examples

All in `examples/games/`, all art made in code:

| program | shows |
|---|---|
| `pong.va` | `update(dt)`/`draw()`, keys and mouse, collisions, `beep` |
| `snake.va` | the Vanta Studio API (`canvas`, `on_frame`, `text_at`) — runs in the IDE too |
| `platformer.va` | pixel art from text, a drawn tileset, `draw_tilemap`, `Body` physics, camera, parallax, enemies, particles |
| `breakout.va` | `Rect` + `hit_side`, mouse control, screen shake with the camera, TTF text |
| `paint.va` | drawing into an image (`draw_to`), the mouse, `save_image` |
| `calculator.va` | `lib/gui.va` buttons in a layout grid, keyboard input |
| `todo.va` | `lib/gui.va` text field, checkboxes, scrolling, a resizable window, saving JSON |
| `showcase.va` | every kind of shape, transparency, fonts, rotated images, off-screen images, a zooming camera |

---

## Moving programs between Vanta Studio and native

The browser IDE's canvas names work natively too: `canvas(w, h)`, `clear(colour)`,
`color(colour)`, `rect`, `circle`, `line`, `text_at(x, y, text, size)`, `key_down(key)`,
`mouse_x()`, `mouse_y()`, `mouse_down()`, `stop_game()` and `on_frame()`. Two
differences: the IDE runs `on_frame` 30 times a second and native 60 (call
`frame_rate(30)` to match), and the IDE draws text with the browser's monospace font
while native uses the 8 x 8 pixel font (call `font("mono")` for a closer look).
Everything else on this page is native-only.

## The GBA mode

The original game runtime — a Game Boy Advance-style video chip (`game_open`,
`game_frame`, `vram_write`, `oam_set`, `io_write`, ...) used by GBA-style games —
is unchanged and documented at the top of `native/runtime/vgame.c`. A program can use
either mode.
