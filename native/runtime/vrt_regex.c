/* vantac: optional */
/* Vanta native runtime: regular expressions — matches, find_all, replace_all, regex_search, regex_split,
 * regex_escape — with the same results as vanta.py, which uses Python's `re` module.
 *
 * A small backtracking engine that works on code points: the pattern is parsed (Python's sre_parse rules and error
 * messages) into a tree, compiled into a little program, and run by a backtracking machine with an explicit stack
 * (no C recursion except for lookarounds and atomic groups, whose depth is bounded by the pattern's nesting).
 * Supported: literals and escapes (\n \t \xHH \uHHHH \UHHHHHHHH octal ...), ., classes with ranges and \d \w \s,
 * \d \D \w \W \s \S (Unicode, like Python's str patterns), \b \B ^ $ \A \Z, groups, (?:...), (?P<name>...),
 * (?P=name), \1 backrefs, |, * + ? {m} {m,} {m,n} {,n} with lazy (?) and possessive (+) forms, (?=...) (?!...)
 * (?<=...) (?<!...) (fixed width), (?>...) atomic groups, (?(1)yes|no), (?#...), global flags (?aimsux) at the
 * start and scoped flags (?i:...) (?-i:...). A step limit turns runaway backtracking into an error. */
#include "vrt.h"
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdarg.h>
#include <setjmp.h>

#define NEED(n, name) do { if (argc != (n)) vrt_fail("%s expects %d value(s), got %d", name, n, argc); } while (0)
#define NELEM(a) ((int)(sizeof(a) / sizeof((a)[0])))

/* ---- Unicode tables, generated from Python 3.13.2's str methods (alnum, isdecimal, isspace, simple lower/upper) ---- */
static const int32_t rx_word_tab[][2] = {
    {0xAA,0xAA}, {0xB2,0xB3}, {0xB5,0xB5}, {0xB9,0xBA}, {0xBC,0xBE}, {0xC0,0xD6}, {0xD8,0xF6}, {0xF8,0x2C1},
    {0x2C6,0x2D1}, {0x2E0,0x2E4}, {0x2EC,0x2EC}, {0x2EE,0x2EE}, {0x370,0x374}, {0x376,0x377}, {0x37A,0x37D},
    {0x37F,0x37F}, {0x386,0x386}, {0x388,0x38A}, {0x38C,0x38C}, {0x38E,0x3A1}, {0x3A3,0x3F5}, {0x3F7,0x481},
    {0x48A,0x52F}, {0x531,0x556}, {0x559,0x559}, {0x560,0x588}, {0x5D0,0x5EA}, {0x5EF,0x5F2}, {0x620,0x64A},
    {0x660,0x669}, {0x66E,0x66F}, {0x671,0x6D3}, {0x6D5,0x6D5}, {0x6E5,0x6E6}, {0x6EE,0x6FC}, {0x6FF,0x6FF},
    {0x710,0x710}, {0x712,0x72F}, {0x74D,0x7A5}, {0x7B1,0x7B1}, {0x7C0,0x7EA}, {0x7F4,0x7F5}, {0x7FA,0x7FA},
    {0x800,0x815}, {0x81A,0x81A}, {0x824,0x824}, {0x828,0x828}, {0x840,0x858}, {0x860,0x86A}, {0x870,0x887},
    {0x889,0x88E}, {0x8A0,0x8C9}, {0x904,0x939}, {0x93D,0x93D}, {0x950,0x950}, {0x958,0x961}, {0x966,0x96F},
    {0x971,0x980}, {0x985,0x98C}, {0x98F,0x990}, {0x993,0x9A8}, {0x9AA,0x9B0}, {0x9B2,0x9B2}, {0x9B6,0x9B9},
    {0x9BD,0x9BD}, {0x9CE,0x9CE}, {0x9DC,0x9DD}, {0x9DF,0x9E1}, {0x9E6,0x9F1}, {0x9F4,0x9F9}, {0x9FC,0x9FC},
    {0xA05,0xA0A}, {0xA0F,0xA10}, {0xA13,0xA28}, {0xA2A,0xA30}, {0xA32,0xA33}, {0xA35,0xA36}, {0xA38,0xA39},
    {0xA59,0xA5C}, {0xA5E,0xA5E}, {0xA66,0xA6F}, {0xA72,0xA74}, {0xA85,0xA8D}, {0xA8F,0xA91}, {0xA93,0xAA8},
    {0xAAA,0xAB0}, {0xAB2,0xAB3}, {0xAB5,0xAB9}, {0xABD,0xABD}, {0xAD0,0xAD0}, {0xAE0,0xAE1}, {0xAE6,0xAEF},
    {0xAF9,0xAF9}, {0xB05,0xB0C}, {0xB0F,0xB10}, {0xB13,0xB28}, {0xB2A,0xB30}, {0xB32,0xB33}, {0xB35,0xB39},
    {0xB3D,0xB3D}, {0xB5C,0xB5D}, {0xB5F,0xB61}, {0xB66,0xB6F}, {0xB71,0xB77}, {0xB83,0xB83}, {0xB85,0xB8A},
    {0xB8E,0xB90}, {0xB92,0xB95}, {0xB99,0xB9A}, {0xB9C,0xB9C}, {0xB9E,0xB9F}, {0xBA3,0xBA4}, {0xBA8,0xBAA},
    {0xBAE,0xBB9}, {0xBD0,0xBD0}, {0xBE6,0xBF2}, {0xC05,0xC0C}, {0xC0E,0xC10}, {0xC12,0xC28}, {0xC2A,0xC39},
    {0xC3D,0xC3D}, {0xC58,0xC5A}, {0xC5D,0xC5D}, {0xC60,0xC61}, {0xC66,0xC6F}, {0xC78,0xC7E}, {0xC80,0xC80},
    {0xC85,0xC8C}, {0xC8E,0xC90}, {0xC92,0xCA8}, {0xCAA,0xCB3}, {0xCB5,0xCB9}, {0xCBD,0xCBD}, {0xCDD,0xCDE},
    {0xCE0,0xCE1}, {0xCE6,0xCEF}, {0xCF1,0xCF2}, {0xD04,0xD0C}, {0xD0E,0xD10}, {0xD12,0xD3A}, {0xD3D,0xD3D},
    {0xD4E,0xD4E}, {0xD54,0xD56}, {0xD58,0xD61}, {0xD66,0xD78}, {0xD7A,0xD7F}, {0xD85,0xD96}, {0xD9A,0xDB1},
    {0xDB3,0xDBB}, {0xDBD,0xDBD}, {0xDC0,0xDC6}, {0xDE6,0xDEF}, {0xE01,0xE30}, {0xE32,0xE33}, {0xE40,0xE46},
    {0xE50,0xE59}, {0xE81,0xE82}, {0xE84,0xE84}, {0xE86,0xE8A}, {0xE8C,0xEA3}, {0xEA5,0xEA5}, {0xEA7,0xEB0},
    {0xEB2,0xEB3}, {0xEBD,0xEBD}, {0xEC0,0xEC4}, {0xEC6,0xEC6}, {0xED0,0xED9}, {0xEDC,0xEDF}, {0xF00,0xF00},
    {0xF20,0xF33}, {0xF40,0xF47}, {0xF49,0xF6C}, {0xF88,0xF8C}, {0x1000,0x102A}, {0x103F,0x1049}, {0x1050,0x1055},
    {0x105A,0x105D}, {0x1061,0x1061}, {0x1065,0x1066}, {0x106E,0x1070}, {0x1075,0x1081}, {0x108E,0x108E},
    {0x1090,0x1099}, {0x10A0,0x10C5}, {0x10C7,0x10C7}, {0x10CD,0x10CD}, {0x10D0,0x10FA}, {0x10FC,0x1248},
    {0x124A,0x124D}, {0x1250,0x1256}, {0x1258,0x1258}, {0x125A,0x125D}, {0x1260,0x1288}, {0x128A,0x128D},
    {0x1290,0x12B0}, {0x12B2,0x12B5}, {0x12B8,0x12BE}, {0x12C0,0x12C0}, {0x12C2,0x12C5}, {0x12C8,0x12D6},
    {0x12D8,0x1310}, {0x1312,0x1315}, {0x1318,0x135A}, {0x1369,0x137C}, {0x1380,0x138F}, {0x13A0,0x13F5},
    {0x13F8,0x13FD}, {0x1401,0x166C}, {0x166F,0x167F}, {0x1681,0x169A}, {0x16A0,0x16EA}, {0x16EE,0x16F8},
    {0x1700,0x1711}, {0x171F,0x1731}, {0x1740,0x1751}, {0x1760,0x176C}, {0x176E,0x1770}, {0x1780,0x17B3},
    {0x17D7,0x17D7}, {0x17DC,0x17DC}, {0x17E0,0x17E9}, {0x17F0,0x17F9}, {0x1810,0x1819}, {0x1820,0x1878},
    {0x1880,0x1884}, {0x1887,0x18A8}, {0x18AA,0x18AA}, {0x18B0,0x18F5}, {0x1900,0x191E}, {0x1946,0x196D},
    {0x1970,0x1974}, {0x1980,0x19AB}, {0x19B0,0x19C9}, {0x19D0,0x19DA}, {0x1A00,0x1A16}, {0x1A20,0x1A54},
    {0x1A80,0x1A89}, {0x1A90,0x1A99}, {0x1AA7,0x1AA7}, {0x1B05,0x1B33}, {0x1B45,0x1B4C}, {0x1B50,0x1B59},
    {0x1B83,0x1BA0}, {0x1BAE,0x1BE5}, {0x1C00,0x1C23}, {0x1C40,0x1C49}, {0x1C4D,0x1C7D}, {0x1C80,0x1C88},
    {0x1C90,0x1CBA}, {0x1CBD,0x1CBF}, {0x1CE9,0x1CEC}, {0x1CEE,0x1CF3}, {0x1CF5,0x1CF6}, {0x1CFA,0x1CFA},
    {0x1D00,0x1DBF}, {0x1E00,0x1F15}, {0x1F18,0x1F1D}, {0x1F20,0x1F45}, {0x1F48,0x1F4D}, {0x1F50,0x1F57},
    {0x1F59,0x1F59}, {0x1F5B,0x1F5B}, {0x1F5D,0x1F5D}, {0x1F5F,0x1F7D}, {0x1F80,0x1FB4}, {0x1FB6,0x1FBC},
    {0x1FBE,0x1FBE}, {0x1FC2,0x1FC4}, {0x1FC6,0x1FCC}, {0x1FD0,0x1FD3}, {0x1FD6,0x1FDB}, {0x1FE0,0x1FEC},
    {0x1FF2,0x1FF4}, {0x1FF6,0x1FFC}, {0x2070,0x2071}, {0x2074,0x2079}, {0x207F,0x2089}, {0x2090,0x209C},
    {0x2102,0x2102}, {0x2107,0x2107}, {0x210A,0x2113}, {0x2115,0x2115}, {0x2119,0x211D}, {0x2124,0x2124},
    {0x2126,0x2126}, {0x2128,0x2128}, {0x212A,0x212D}, {0x212F,0x2139}, {0x213C,0x213F}, {0x2145,0x2149},
    {0x214E,0x214E}, {0x2150,0x2189}, {0x2460,0x249B}, {0x24EA,0x24FF}, {0x2776,0x2793}, {0x2C00,0x2CE4},
    {0x2CEB,0x2CEE}, {0x2CF2,0x2CF3}, {0x2CFD,0x2CFD}, {0x2D00,0x2D25}, {0x2D27,0x2D27}, {0x2D2D,0x2D2D},
    {0x2D30,0x2D67}, {0x2D6F,0x2D6F}, {0x2D80,0x2D96}, {0x2DA0,0x2DA6}, {0x2DA8,0x2DAE}, {0x2DB0,0x2DB6},
    {0x2DB8,0x2DBE}, {0x2DC0,0x2DC6}, {0x2DC8,0x2DCE}, {0x2DD0,0x2DD6}, {0x2DD8,0x2DDE}, {0x2E2F,0x2E2F},
    {0x3005,0x3007}, {0x3021,0x3029}, {0x3031,0x3035}, {0x3038,0x303C}, {0x3041,0x3096}, {0x309D,0x309F},
    {0x30A1,0x30FA}, {0x30FC,0x30FF}, {0x3105,0x312F}, {0x3131,0x318E}, {0x3192,0x3195}, {0x31A0,0x31BF},
    {0x31F0,0x31FF}, {0x3220,0x3229}, {0x3248,0x324F}, {0x3251,0x325F}, {0x3280,0x3289}, {0x32B1,0x32BF},
    {0x3400,0x4DBF}, {0x4E00,0xA48C}, {0xA4D0,0xA4FD}, {0xA500,0xA60C}, {0xA610,0xA62B}, {0xA640,0xA66E},
    {0xA67F,0xA69D}, {0xA6A0,0xA6EF}, {0xA717,0xA71F}, {0xA722,0xA788}, {0xA78B,0xA7CA}, {0xA7D0,0xA7D1},
    {0xA7D3,0xA7D3}, {0xA7D5,0xA7D9}, {0xA7F2,0xA801}, {0xA803,0xA805}, {0xA807,0xA80A}, {0xA80C,0xA822},
    {0xA830,0xA835}, {0xA840,0xA873}, {0xA882,0xA8B3}, {0xA8D0,0xA8D9}, {0xA8F2,0xA8F7}, {0xA8FB,0xA8FB},
    {0xA8FD,0xA8FE}, {0xA900,0xA925}, {0xA930,0xA946}, {0xA960,0xA97C}, {0xA984,0xA9B2}, {0xA9CF,0xA9D9},
    {0xA9E0,0xA9E4}, {0xA9E6,0xA9FE}, {0xAA00,0xAA28}, {0xAA40,0xAA42}, {0xAA44,0xAA4B}, {0xAA50,0xAA59},
    {0xAA60,0xAA76}, {0xAA7A,0xAA7A}, {0xAA7E,0xAAAF}, {0xAAB1,0xAAB1}, {0xAAB5,0xAAB6}, {0xAAB9,0xAABD},
    {0xAAC0,0xAAC0}, {0xAAC2,0xAAC2}, {0xAADB,0xAADD}, {0xAAE0,0xAAEA}, {0xAAF2,0xAAF4}, {0xAB01,0xAB06},
    {0xAB09,0xAB0E}, {0xAB11,0xAB16}, {0xAB20,0xAB26}, {0xAB28,0xAB2E}, {0xAB30,0xAB5A}, {0xAB5C,0xAB69},
    {0xAB70,0xABE2}, {0xABF0,0xABF9}, {0xAC00,0xD7A3}, {0xD7B0,0xD7C6}, {0xD7CB,0xD7FB}, {0xF900,0xFA6D},
    {0xFA70,0xFAD9}, {0xFB00,0xFB06}, {0xFB13,0xFB17}, {0xFB1D,0xFB1D}, {0xFB1F,0xFB28}, {0xFB2A,0xFB36},
    {0xFB38,0xFB3C}, {0xFB3E,0xFB3E}, {0xFB40,0xFB41}, {0xFB43,0xFB44}, {0xFB46,0xFBB1}, {0xFBD3,0xFD3D},
    {0xFD50,0xFD8F}, {0xFD92,0xFDC7}, {0xFDF0,0xFDFB}, {0xFE70,0xFE74}, {0xFE76,0xFEFC}, {0xFF10,0xFF19},
    {0xFF21,0xFF3A}, {0xFF41,0xFF5A}, {0xFF66,0xFFBE}, {0xFFC2,0xFFC7}, {0xFFCA,0xFFCF}, {0xFFD2,0xFFD7},
    {0xFFDA,0xFFDC}, {0x10000,0x1000B}, {0x1000D,0x10026}, {0x10028,0x1003A}, {0x1003C,0x1003D}, {0x1003F,0x1004D},
    {0x10050,0x1005D}, {0x10080,0x100FA}, {0x10107,0x10133}, {0x10140,0x10178}, {0x1018A,0x1018B}, {0x10280,0x1029C},
    {0x102A0,0x102D0}, {0x102E1,0x102FB}, {0x10300,0x10323}, {0x1032D,0x1034A}, {0x10350,0x10375}, {0x10380,0x1039D},
    {0x103A0,0x103C3}, {0x103C8,0x103CF}, {0x103D1,0x103D5}, {0x10400,0x1049D}, {0x104A0,0x104A9}, {0x104B0,0x104D3},
    {0x104D8,0x104FB}, {0x10500,0x10527}, {0x10530,0x10563}, {0x10570,0x1057A}, {0x1057C,0x1058A}, {0x1058C,0x10592},
    {0x10594,0x10595}, {0x10597,0x105A1}, {0x105A3,0x105B1}, {0x105B3,0x105B9}, {0x105BB,0x105BC}, {0x10600,0x10736},
    {0x10740,0x10755}, {0x10760,0x10767}, {0x10780,0x10785}, {0x10787,0x107B0}, {0x107B2,0x107BA}, {0x10800,0x10805},
    {0x10808,0x10808}, {0x1080A,0x10835}, {0x10837,0x10838}, {0x1083C,0x1083C}, {0x1083F,0x10855}, {0x10858,0x10876},
    {0x10879,0x1089E}, {0x108A7,0x108AF}, {0x108E0,0x108F2}, {0x108F4,0x108F5}, {0x108FB,0x1091B}, {0x10920,0x10939},
    {0x10980,0x109B7}, {0x109BC,0x109CF}, {0x109D2,0x10A00}, {0x10A10,0x10A13}, {0x10A15,0x10A17}, {0x10A19,0x10A35},
    {0x10A40,0x10A48}, {0x10A60,0x10A7E}, {0x10A80,0x10A9F}, {0x10AC0,0x10AC7}, {0x10AC9,0x10AE4}, {0x10AEB,0x10AEF},
    {0x10B00,0x10B35}, {0x10B40,0x10B55}, {0x10B58,0x10B72}, {0x10B78,0x10B91}, {0x10BA9,0x10BAF}, {0x10C00,0x10C48},
    {0x10C80,0x10CB2}, {0x10CC0,0x10CF2}, {0x10CFA,0x10D23}, {0x10D30,0x10D39}, {0x10E60,0x10E7E}, {0x10E80,0x10EA9},
    {0x10EB0,0x10EB1}, {0x10F00,0x10F27}, {0x10F30,0x10F45}, {0x10F51,0x10F54}, {0x10F70,0x10F81}, {0x10FB0,0x10FCB},
    {0x10FE0,0x10FF6}, {0x11003,0x11037}, {0x11052,0x1106F}, {0x11071,0x11072}, {0x11075,0x11075}, {0x11083,0x110AF},
    {0x110D0,0x110E8}, {0x110F0,0x110F9}, {0x11103,0x11126}, {0x11136,0x1113F}, {0x11144,0x11144}, {0x11147,0x11147},
    {0x11150,0x11172}, {0x11176,0x11176}, {0x11183,0x111B2}, {0x111C1,0x111C4}, {0x111D0,0x111DA}, {0x111DC,0x111DC},
    {0x111E1,0x111F4}, {0x11200,0x11211}, {0x11213,0x1122B}, {0x1123F,0x11240}, {0x11280,0x11286}, {0x11288,0x11288},
    {0x1128A,0x1128D}, {0x1128F,0x1129D}, {0x1129F,0x112A8}, {0x112B0,0x112DE}, {0x112F0,0x112F9}, {0x11305,0x1130C},
    {0x1130F,0x11310}, {0x11313,0x11328}, {0x1132A,0x11330}, {0x11332,0x11333}, {0x11335,0x11339}, {0x1133D,0x1133D},
    {0x11350,0x11350}, {0x1135D,0x11361}, {0x11400,0x11434}, {0x11447,0x1144A}, {0x11450,0x11459}, {0x1145F,0x11461},
    {0x11480,0x114AF}, {0x114C4,0x114C5}, {0x114C7,0x114C7}, {0x114D0,0x114D9}, {0x11580,0x115AE}, {0x115D8,0x115DB},
    {0x11600,0x1162F}, {0x11644,0x11644}, {0x11650,0x11659}, {0x11680,0x116AA}, {0x116B8,0x116B8}, {0x116C0,0x116C9},
    {0x11700,0x1171A}, {0x11730,0x1173B}, {0x11740,0x11746}, {0x11800,0x1182B}, {0x118A0,0x118F2}, {0x118FF,0x11906},
    {0x11909,0x11909}, {0x1190C,0x11913}, {0x11915,0x11916}, {0x11918,0x1192F}, {0x1193F,0x1193F}, {0x11941,0x11941},
    {0x11950,0x11959}, {0x119A0,0x119A7}, {0x119AA,0x119D0}, {0x119E1,0x119E1}, {0x119E3,0x119E3}, {0x11A00,0x11A00},
    {0x11A0B,0x11A32}, {0x11A3A,0x11A3A}, {0x11A50,0x11A50}, {0x11A5C,0x11A89}, {0x11A9D,0x11A9D}, {0x11AB0,0x11AF8},
    {0x11C00,0x11C08}, {0x11C0A,0x11C2E}, {0x11C40,0x11C40}, {0x11C50,0x11C6C}, {0x11C72,0x11C8F}, {0x11D00,0x11D06},
    {0x11D08,0x11D09}, {0x11D0B,0x11D30}, {0x11D46,0x11D46}, {0x11D50,0x11D59}, {0x11D60,0x11D65}, {0x11D67,0x11D68},
    {0x11D6A,0x11D89}, {0x11D98,0x11D98}, {0x11DA0,0x11DA9}, {0x11EE0,0x11EF2}, {0x11F02,0x11F02}, {0x11F04,0x11F10},
    {0x11F12,0x11F33}, {0x11F50,0x11F59}, {0x11FB0,0x11FB0}, {0x11FC0,0x11FD4}, {0x12000,0x12399}, {0x12400,0x1246E},
    {0x12480,0x12543}, {0x12F90,0x12FF0}, {0x13000,0x1342F}, {0x13441,0x13446}, {0x14400,0x14646}, {0x16800,0x16A38},
    {0x16A40,0x16A5E}, {0x16A60,0x16A69}, {0x16A70,0x16ABE}, {0x16AC0,0x16AC9}, {0x16AD0,0x16AED}, {0x16B00,0x16B2F},
    {0x16B40,0x16B43}, {0x16B50,0x16B59}, {0x16B5B,0x16B61}, {0x16B63,0x16B77}, {0x16B7D,0x16B8F}, {0x16E40,0x16E96},
    {0x16F00,0x16F4A}, {0x16F50,0x16F50}, {0x16F93,0x16F9F}, {0x16FE0,0x16FE1}, {0x16FE3,0x16FE3}, {0x17000,0x187F7},
    {0x18800,0x18CD5}, {0x18D00,0x18D08}, {0x1AFF0,0x1AFF3}, {0x1AFF5,0x1AFFB}, {0x1AFFD,0x1AFFE}, {0x1B000,0x1B122},
    {0x1B132,0x1B132}, {0x1B150,0x1B152}, {0x1B155,0x1B155}, {0x1B164,0x1B167}, {0x1B170,0x1B2FB}, {0x1BC00,0x1BC6A},
    {0x1BC70,0x1BC7C}, {0x1BC80,0x1BC88}, {0x1BC90,0x1BC99}, {0x1D2C0,0x1D2D3}, {0x1D2E0,0x1D2F3}, {0x1D360,0x1D378},
    {0x1D400,0x1D454}, {0x1D456,0x1D49C}, {0x1D49E,0x1D49F}, {0x1D4A2,0x1D4A2}, {0x1D4A5,0x1D4A6}, {0x1D4A9,0x1D4AC},
    {0x1D4AE,0x1D4B9}, {0x1D4BB,0x1D4BB}, {0x1D4BD,0x1D4C3}, {0x1D4C5,0x1D505}, {0x1D507,0x1D50A}, {0x1D50D,0x1D514},
    {0x1D516,0x1D51C}, {0x1D51E,0x1D539}, {0x1D53B,0x1D53E}, {0x1D540,0x1D544}, {0x1D546,0x1D546}, {0x1D54A,0x1D550},
    {0x1D552,0x1D6A5}, {0x1D6A8,0x1D6C0}, {0x1D6C2,0x1D6DA}, {0x1D6DC,0x1D6FA}, {0x1D6FC,0x1D714}, {0x1D716,0x1D734},
    {0x1D736,0x1D74E}, {0x1D750,0x1D76E}, {0x1D770,0x1D788}, {0x1D78A,0x1D7A8}, {0x1D7AA,0x1D7C2}, {0x1D7C4,0x1D7CB},
    {0x1D7CE,0x1D7FF}, {0x1DF00,0x1DF1E}, {0x1DF25,0x1DF2A}, {0x1E030,0x1E06D}, {0x1E100,0x1E12C}, {0x1E137,0x1E13D},
    {0x1E140,0x1E149}, {0x1E14E,0x1E14E}, {0x1E290,0x1E2AD}, {0x1E2C0,0x1E2EB}, {0x1E2F0,0x1E2F9}, {0x1E4D0,0x1E4EB},
    {0x1E4F0,0x1E4F9}, {0x1E7E0,0x1E7E6}, {0x1E7E8,0x1E7EB}, {0x1E7ED,0x1E7EE}, {0x1E7F0,0x1E7FE}, {0x1E800,0x1E8C4},
    {0x1E8C7,0x1E8CF}, {0x1E900,0x1E943}, {0x1E94B,0x1E94B}, {0x1E950,0x1E959}, {0x1EC71,0x1ECAB}, {0x1ECAD,0x1ECAF},
    {0x1ECB1,0x1ECB4}, {0x1ED01,0x1ED2D}, {0x1ED2F,0x1ED3D}, {0x1EE00,0x1EE03}, {0x1EE05,0x1EE1F}, {0x1EE21,0x1EE22},
    {0x1EE24,0x1EE24}, {0x1EE27,0x1EE27}, {0x1EE29,0x1EE32}, {0x1EE34,0x1EE37}, {0x1EE39,0x1EE39}, {0x1EE3B,0x1EE3B},
    {0x1EE42,0x1EE42}, {0x1EE47,0x1EE47}, {0x1EE49,0x1EE49}, {0x1EE4B,0x1EE4B}, {0x1EE4D,0x1EE4F}, {0x1EE51,0x1EE52},
    {0x1EE54,0x1EE54}, {0x1EE57,0x1EE57}, {0x1EE59,0x1EE59}, {0x1EE5B,0x1EE5B}, {0x1EE5D,0x1EE5D}, {0x1EE5F,0x1EE5F},
    {0x1EE61,0x1EE62}, {0x1EE64,0x1EE64}, {0x1EE67,0x1EE6A}, {0x1EE6C,0x1EE72}, {0x1EE74,0x1EE77}, {0x1EE79,0x1EE7C},
    {0x1EE7E,0x1EE7E}, {0x1EE80,0x1EE89}, {0x1EE8B,0x1EE9B}, {0x1EEA1,0x1EEA3}, {0x1EEA5,0x1EEA9}, {0x1EEAB,0x1EEBB},
    {0x1F100,0x1F10C}, {0x1FBF0,0x1FBF9}, {0x20000,0x2A6DF}, {0x2A700,0x2B739}, {0x2B740,0x2B81D}, {0x2B820,0x2CEA1},
    {0x2CEB0,0x2EBE0}, {0x2EBF0,0x2EE5D}, {0x2F800,0x2FA1D}, {0x30000,0x3134A}, {0x31350,0x323AF},
};

static const int32_t rx_digit_tab[][2] = {
    {0x660,0x669}, {0x6F0,0x6F9}, {0x7C0,0x7C9}, {0x966,0x96F}, {0x9E6,0x9EF}, {0xA66,0xA6F}, {0xAE6,0xAEF},
    {0xB66,0xB6F}, {0xBE6,0xBEF}, {0xC66,0xC6F}, {0xCE6,0xCEF}, {0xD66,0xD6F}, {0xDE6,0xDEF}, {0xE50,0xE59},
    {0xED0,0xED9}, {0xF20,0xF29}, {0x1040,0x1049}, {0x1090,0x1099}, {0x17E0,0x17E9}, {0x1810,0x1819}, {0x1946,0x194F},
    {0x19D0,0x19D9}, {0x1A80,0x1A89}, {0x1A90,0x1A99}, {0x1B50,0x1B59}, {0x1BB0,0x1BB9}, {0x1C40,0x1C49},
    {0x1C50,0x1C59}, {0xA620,0xA629}, {0xA8D0,0xA8D9}, {0xA900,0xA909}, {0xA9D0,0xA9D9}, {0xA9F0,0xA9F9},
    {0xAA50,0xAA59}, {0xABF0,0xABF9}, {0xFF10,0xFF19}, {0x104A0,0x104A9}, {0x10D30,0x10D39}, {0x11066,0x1106F},
    {0x110F0,0x110F9}, {0x11136,0x1113F}, {0x111D0,0x111D9}, {0x112F0,0x112F9}, {0x11450,0x11459}, {0x114D0,0x114D9},
    {0x11650,0x11659}, {0x116C0,0x116C9}, {0x11730,0x11739}, {0x118E0,0x118E9}, {0x11950,0x11959}, {0x11C50,0x11C59},
    {0x11D50,0x11D59}, {0x11DA0,0x11DA9}, {0x11F50,0x11F59}, {0x16A60,0x16A69}, {0x16AC0,0x16AC9}, {0x16B50,0x16B59},
    {0x1D7CE,0x1D7FF}, {0x1E140,0x1E149}, {0x1E2F0,0x1E2F9}, {0x1E4F0,0x1E4F9}, {0x1E950,0x1E959}, {0x1FBF0,0x1FBF9},
};

static const int32_t rx_lower_tab[][4] = {
    {0x41,0x5A,0x1,0x20}, {0xC0,0xD6,0x1,0x20}, {0xD8,0xDE,0x1,0x20}, {0x100,0x12E,0x2,0x1}, {0x132,0x136,0x2,0x1},
    {0x139,0x147,0x2,0x1}, {0x14A,0x176,0x2,0x1}, {0x178,0x178,0x1,-0x79}, {0x179,0x17D,0x2,0x1},
    {0x181,0x181,0x1,0xD2}, {0x182,0x184,0x2,0x1}, {0x186,0x186,0x1,0xCE}, {0x187,0x187,0x1,0x1},
    {0x189,0x18A,0x1,0xCD}, {0x18B,0x18B,0x1,0x1}, {0x18E,0x18E,0x1,0x4F}, {0x18F,0x18F,0x1,0xCA},
    {0x190,0x190,0x1,0xCB}, {0x191,0x191,0x1,0x1}, {0x193,0x193,0x1,0xCD}, {0x194,0x194,0x1,0xCF},
    {0x196,0x196,0x1,0xD3}, {0x197,0x197,0x1,0xD1}, {0x198,0x198,0x1,0x1}, {0x19C,0x19C,0x1,0xD3},
    {0x19D,0x19D,0x1,0xD5}, {0x19F,0x19F,0x1,0xD6}, {0x1A0,0x1A4,0x2,0x1}, {0x1A6,0x1A6,0x1,0xDA},
    {0x1A7,0x1A7,0x1,0x1}, {0x1A9,0x1A9,0x1,0xDA}, {0x1AC,0x1AC,0x1,0x1}, {0x1AE,0x1AE,0x1,0xDA},
    {0x1AF,0x1AF,0x1,0x1}, {0x1B1,0x1B2,0x1,0xD9}, {0x1B3,0x1B5,0x2,0x1}, {0x1B7,0x1B7,0x1,0xDB},
    {0x1B8,0x1B8,0x1,0x1}, {0x1BC,0x1BC,0x1,0x1}, {0x1C4,0x1C4,0x1,0x2}, {0x1C5,0x1C5,0x1,0x1}, {0x1C7,0x1C7,0x1,0x2},
    {0x1C8,0x1C8,0x1,0x1}, {0x1CA,0x1CA,0x1,0x2}, {0x1CB,0x1DB,0x2,0x1}, {0x1DE,0x1EE,0x2,0x1}, {0x1F1,0x1F1,0x1,0x2},
    {0x1F2,0x1F4,0x2,0x1}, {0x1F6,0x1F6,0x1,-0x61}, {0x1F7,0x1F7,0x1,-0x38}, {0x1F8,0x21E,0x2,0x1},
    {0x220,0x220,0x1,-0x82}, {0x222,0x232,0x2,0x1}, {0x23A,0x23A,0x1,0x2A2B}, {0x23B,0x23B,0x1,0x1},
    {0x23D,0x23D,0x1,-0xA3}, {0x23E,0x23E,0x1,0x2A28}, {0x241,0x241,0x1,0x1}, {0x243,0x243,0x1,-0xC3},
    {0x244,0x244,0x1,0x45}, {0x245,0x245,0x1,0x47}, {0x246,0x24E,0x2,0x1}, {0x370,0x372,0x2,0x1},
    {0x376,0x376,0x1,0x1}, {0x37F,0x37F,0x1,0x74}, {0x386,0x386,0x1,0x26}, {0x388,0x38A,0x1,0x25},
    {0x38C,0x38C,0x1,0x40}, {0x38E,0x38F,0x1,0x3F}, {0x391,0x3A1,0x1,0x20}, {0x3A3,0x3AB,0x1,0x20},
    {0x3CF,0x3CF,0x1,0x8}, {0x3D8,0x3EE,0x2,0x1}, {0x3F4,0x3F4,0x1,-0x3C}, {0x3F7,0x3F7,0x1,0x1},
    {0x3F9,0x3F9,0x1,-0x7}, {0x3FA,0x3FA,0x1,0x1}, {0x3FD,0x3FF,0x1,-0x82}, {0x400,0x40F,0x1,0x50},
    {0x410,0x42F,0x1,0x20}, {0x460,0x480,0x2,0x1}, {0x48A,0x4BE,0x2,0x1}, {0x4C0,0x4C0,0x1,0xF},
    {0x4C1,0x4CD,0x2,0x1}, {0x4D0,0x52E,0x2,0x1}, {0x531,0x556,0x1,0x30}, {0x10A0,0x10C5,0x1,0x1C60},
    {0x10C7,0x10C7,0x1,0x1C60}, {0x10CD,0x10CD,0x1,0x1C60}, {0x13A0,0x13EF,0x1,0x97D0}, {0x13F0,0x13F5,0x1,0x8},
    {0x1C90,0x1CBA,0x1,-0xBC0}, {0x1CBD,0x1CBF,0x1,-0xBC0}, {0x1E00,0x1E94,0x2,0x1}, {0x1E9E,0x1E9E,0x1,-0x1DBF},
    {0x1EA0,0x1EFE,0x2,0x1}, {0x1F08,0x1F0F,0x1,-0x8}, {0x1F18,0x1F1D,0x1,-0x8}, {0x1F28,0x1F2F,0x1,-0x8},
    {0x1F38,0x1F3F,0x1,-0x8}, {0x1F48,0x1F4D,0x1,-0x8}, {0x1F59,0x1F5F,0x2,-0x8}, {0x1F68,0x1F6F,0x1,-0x8},
    {0x1F88,0x1F8F,0x1,-0x8}, {0x1F98,0x1F9F,0x1,-0x8}, {0x1FA8,0x1FAF,0x1,-0x8}, {0x1FB8,0x1FB9,0x1,-0x8},
    {0x1FBA,0x1FBB,0x1,-0x4A}, {0x1FBC,0x1FBC,0x1,-0x9}, {0x1FC8,0x1FCB,0x1,-0x56}, {0x1FCC,0x1FCC,0x1,-0x9},
    {0x1FD8,0x1FD9,0x1,-0x8}, {0x1FDA,0x1FDB,0x1,-0x64}, {0x1FE8,0x1FE9,0x1,-0x8}, {0x1FEA,0x1FEB,0x1,-0x70},
    {0x1FEC,0x1FEC,0x1,-0x7}, {0x1FF8,0x1FF9,0x1,-0x80}, {0x1FFA,0x1FFB,0x1,-0x7E}, {0x1FFC,0x1FFC,0x1,-0x9},
    {0x2126,0x2126,0x1,-0x1D5D}, {0x212A,0x212A,0x1,-0x20BF}, {0x212B,0x212B,0x1,-0x2046}, {0x2132,0x2132,0x1,0x1C},
    {0x2160,0x216F,0x1,0x10}, {0x2183,0x2183,0x1,0x1}, {0x24B6,0x24CF,0x1,0x1A}, {0x2C00,0x2C2F,0x1,0x30},
    {0x2C60,0x2C60,0x1,0x1}, {0x2C62,0x2C62,0x1,-0x29F7}, {0x2C63,0x2C63,0x1,-0xEE6}, {0x2C64,0x2C64,0x1,-0x29E7},
    {0x2C67,0x2C6B,0x2,0x1}, {0x2C6D,0x2C6D,0x1,-0x2A1C}, {0x2C6E,0x2C6E,0x1,-0x29FD}, {0x2C6F,0x2C6F,0x1,-0x2A1F},
    {0x2C70,0x2C70,0x1,-0x2A1E}, {0x2C72,0x2C72,0x1,0x1}, {0x2C75,0x2C75,0x1,0x1}, {0x2C7E,0x2C7F,0x1,-0x2A3F},
    {0x2C80,0x2CE2,0x2,0x1}, {0x2CEB,0x2CED,0x2,0x1}, {0x2CF2,0x2CF2,0x1,0x1}, {0xA640,0xA66C,0x2,0x1},
    {0xA680,0xA69A,0x2,0x1}, {0xA722,0xA72E,0x2,0x1}, {0xA732,0xA76E,0x2,0x1}, {0xA779,0xA77B,0x2,0x1},
    {0xA77D,0xA77D,0x1,-0x8A04}, {0xA77E,0xA786,0x2,0x1}, {0xA78B,0xA78B,0x1,0x1}, {0xA78D,0xA78D,0x1,-0xA528},
    {0xA790,0xA792,0x2,0x1}, {0xA796,0xA7A8,0x2,0x1}, {0xA7AA,0xA7AA,0x1,-0xA544}, {0xA7AB,0xA7AB,0x1,-0xA54F},
    {0xA7AC,0xA7AC,0x1,-0xA54B}, {0xA7AD,0xA7AD,0x1,-0xA541}, {0xA7AE,0xA7AE,0x1,-0xA544},
    {0xA7B0,0xA7B0,0x1,-0xA512}, {0xA7B1,0xA7B1,0x1,-0xA52A}, {0xA7B2,0xA7B2,0x1,-0xA515}, {0xA7B3,0xA7B3,0x1,0x3A0},
    {0xA7B4,0xA7C2,0x2,0x1}, {0xA7C4,0xA7C4,0x1,-0x30}, {0xA7C5,0xA7C5,0x1,-0xA543}, {0xA7C6,0xA7C6,0x1,-0x8A38},
    {0xA7C7,0xA7C9,0x2,0x1}, {0xA7D0,0xA7D0,0x1,0x1}, {0xA7D6,0xA7D8,0x2,0x1}, {0xA7F5,0xA7F5,0x1,0x1},
    {0xFF21,0xFF3A,0x1,0x20}, {0x10400,0x10427,0x1,0x28}, {0x104B0,0x104D3,0x1,0x28}, {0x10570,0x1057A,0x1,0x27},
    {0x1057C,0x1058A,0x1,0x27}, {0x1058C,0x10592,0x1,0x27}, {0x10594,0x10595,0x1,0x27}, {0x10C80,0x10CB2,0x1,0x40},
    {0x118A0,0x118BF,0x1,0x20}, {0x16E40,0x16E5F,0x1,0x20}, {0x1E900,0x1E921,0x1,0x22},
};

static const int32_t rx_upper_tab[][4] = {
    {0x61,0x7A,0x1,-0x20}, {0xB5,0xB5,0x1,0x2E7}, {0xE0,0xF6,0x1,-0x20}, {0xF8,0xFE,0x1,-0x20}, {0xFF,0xFF,0x1,0x79},
    {0x101,0x12F,0x2,-0x1}, {0x131,0x131,0x1,-0xE8}, {0x133,0x137,0x2,-0x1}, {0x13A,0x148,0x2,-0x1},
    {0x14B,0x177,0x2,-0x1}, {0x17A,0x17E,0x2,-0x1}, {0x17F,0x17F,0x1,-0x12C}, {0x180,0x180,0x1,0xC3},
    {0x183,0x185,0x2,-0x1}, {0x188,0x188,0x1,-0x1}, {0x18C,0x18C,0x1,-0x1}, {0x192,0x192,0x1,-0x1},
    {0x195,0x195,0x1,0x61}, {0x199,0x199,0x1,-0x1}, {0x19A,0x19A,0x1,0xA3}, {0x19E,0x19E,0x1,0x82},
    {0x1A1,0x1A5,0x2,-0x1}, {0x1A8,0x1A8,0x1,-0x1}, {0x1AD,0x1AD,0x1,-0x1}, {0x1B0,0x1B0,0x1,-0x1},
    {0x1B4,0x1B6,0x2,-0x1}, {0x1B9,0x1B9,0x1,-0x1}, {0x1BD,0x1BD,0x1,-0x1}, {0x1BF,0x1BF,0x1,0x38},
    {0x1C5,0x1C5,0x1,-0x1}, {0x1C6,0x1C6,0x1,-0x2}, {0x1C8,0x1C8,0x1,-0x1}, {0x1C9,0x1C9,0x1,-0x2},
    {0x1CB,0x1CB,0x1,-0x1}, {0x1CC,0x1CC,0x1,-0x2}, {0x1CE,0x1DC,0x2,-0x1}, {0x1DD,0x1DD,0x1,-0x4F},
    {0x1DF,0x1EF,0x2,-0x1}, {0x1F2,0x1F2,0x1,-0x1}, {0x1F3,0x1F3,0x1,-0x2}, {0x1F5,0x1F5,0x1,-0x1},
    {0x1F9,0x21F,0x2,-0x1}, {0x223,0x233,0x2,-0x1}, {0x23C,0x23C,0x1,-0x1}, {0x23F,0x240,0x1,0x2A3F},
    {0x242,0x242,0x1,-0x1}, {0x247,0x24F,0x2,-0x1}, {0x250,0x250,0x1,0x2A1F}, {0x251,0x251,0x1,0x2A1C},
    {0x252,0x252,0x1,0x2A1E}, {0x253,0x253,0x1,-0xD2}, {0x254,0x254,0x1,-0xCE}, {0x256,0x257,0x1,-0xCD},
    {0x259,0x259,0x1,-0xCA}, {0x25B,0x25B,0x1,-0xCB}, {0x25C,0x25C,0x1,0xA54F}, {0x260,0x260,0x1,-0xCD},
    {0x261,0x261,0x1,0xA54B}, {0x263,0x263,0x1,-0xCF}, {0x265,0x265,0x1,0xA528}, {0x266,0x266,0x1,0xA544},
    {0x268,0x268,0x1,-0xD1}, {0x269,0x269,0x1,-0xD3}, {0x26A,0x26A,0x1,0xA544}, {0x26B,0x26B,0x1,0x29F7},
    {0x26C,0x26C,0x1,0xA541}, {0x26F,0x26F,0x1,-0xD3}, {0x271,0x271,0x1,0x29FD}, {0x272,0x272,0x1,-0xD5},
    {0x275,0x275,0x1,-0xD6}, {0x27D,0x27D,0x1,0x29E7}, {0x280,0x280,0x1,-0xDA}, {0x282,0x282,0x1,0xA543},
    {0x283,0x283,0x1,-0xDA}, {0x287,0x287,0x1,0xA52A}, {0x288,0x288,0x1,-0xDA}, {0x289,0x289,0x1,-0x45},
    {0x28A,0x28B,0x1,-0xD9}, {0x28C,0x28C,0x1,-0x47}, {0x292,0x292,0x1,-0xDB}, {0x29D,0x29D,0x1,0xA515},
    {0x29E,0x29E,0x1,0xA512}, {0x345,0x345,0x1,0x54}, {0x371,0x373,0x2,-0x1}, {0x377,0x377,0x1,-0x1},
    {0x37B,0x37D,0x1,0x82}, {0x3AC,0x3AC,0x1,-0x26}, {0x3AD,0x3AF,0x1,-0x25}, {0x3B1,0x3C1,0x1,-0x20},
    {0x3C2,0x3C2,0x1,-0x1F}, {0x3C3,0x3CB,0x1,-0x20}, {0x3CC,0x3CC,0x1,-0x40}, {0x3CD,0x3CE,0x1,-0x3F},
    {0x3D0,0x3D0,0x1,-0x3E}, {0x3D1,0x3D1,0x1,-0x39}, {0x3D5,0x3D5,0x1,-0x2F}, {0x3D6,0x3D6,0x1,-0x36},
    {0x3D7,0x3D7,0x1,-0x8}, {0x3D9,0x3EF,0x2,-0x1}, {0x3F0,0x3F0,0x1,-0x56}, {0x3F1,0x3F1,0x1,-0x50},
    {0x3F2,0x3F2,0x1,0x7}, {0x3F3,0x3F3,0x1,-0x74}, {0x3F5,0x3F5,0x1,-0x60}, {0x3F8,0x3F8,0x1,-0x1},
    {0x3FB,0x3FB,0x1,-0x1}, {0x430,0x44F,0x1,-0x20}, {0x450,0x45F,0x1,-0x50}, {0x461,0x481,0x2,-0x1},
    {0x48B,0x4BF,0x2,-0x1}, {0x4C2,0x4CE,0x2,-0x1}, {0x4CF,0x4CF,0x1,-0xF}, {0x4D1,0x52F,0x2,-0x1},
    {0x561,0x586,0x1,-0x30}, {0x10D0,0x10FA,0x1,0xBC0}, {0x10FD,0x10FF,0x1,0xBC0}, {0x13F8,0x13FD,0x1,-0x8},
    {0x1C80,0x1C80,0x1,-0x186E}, {0x1C81,0x1C81,0x1,-0x186D}, {0x1C82,0x1C82,0x1,-0x1864},
    {0x1C83,0x1C84,0x1,-0x1862}, {0x1C85,0x1C85,0x1,-0x1863}, {0x1C86,0x1C86,0x1,-0x185C},
    {0x1C87,0x1C87,0x1,-0x1825}, {0x1C88,0x1C88,0x1,0x89C2}, {0x1D79,0x1D79,0x1,0x8A04}, {0x1D7D,0x1D7D,0x1,0xEE6},
    {0x1D8E,0x1D8E,0x1,0x8A38}, {0x1E01,0x1E95,0x2,-0x1}, {0x1E9B,0x1E9B,0x1,-0x3B}, {0x1EA1,0x1EFF,0x2,-0x1},
    {0x1F00,0x1F07,0x1,0x8}, {0x1F10,0x1F15,0x1,0x8}, {0x1F20,0x1F27,0x1,0x8}, {0x1F30,0x1F37,0x1,0x8},
    {0x1F40,0x1F45,0x1,0x8}, {0x1F51,0x1F57,0x2,0x8}, {0x1F60,0x1F67,0x1,0x8}, {0x1F70,0x1F71,0x1,0x4A},
    {0x1F72,0x1F75,0x1,0x56}, {0x1F76,0x1F77,0x1,0x64}, {0x1F78,0x1F79,0x1,0x80}, {0x1F7A,0x1F7B,0x1,0x70},
    {0x1F7C,0x1F7D,0x1,0x7E}, {0x1FB0,0x1FB1,0x1,0x8}, {0x1FBE,0x1FBE,0x1,-0x1C25}, {0x1FD0,0x1FD1,0x1,0x8},
    {0x1FE0,0x1FE1,0x1,0x8}, {0x1FE5,0x1FE5,0x1,0x7}, {0x214E,0x214E,0x1,-0x1C}, {0x2170,0x217F,0x1,-0x10},
    {0x2184,0x2184,0x1,-0x1}, {0x24D0,0x24E9,0x1,-0x1A}, {0x2C30,0x2C5F,0x1,-0x30}, {0x2C61,0x2C61,0x1,-0x1},
    {0x2C65,0x2C65,0x1,-0x2A2B}, {0x2C66,0x2C66,0x1,-0x2A28}, {0x2C68,0x2C6C,0x2,-0x1}, {0x2C73,0x2C73,0x1,-0x1},
    {0x2C76,0x2C76,0x1,-0x1}, {0x2C81,0x2CE3,0x2,-0x1}, {0x2CEC,0x2CEE,0x2,-0x1}, {0x2CF3,0x2CF3,0x1,-0x1},
    {0x2D00,0x2D25,0x1,-0x1C60}, {0x2D27,0x2D27,0x1,-0x1C60}, {0x2D2D,0x2D2D,0x1,-0x1C60}, {0xA641,0xA66D,0x2,-0x1},
    {0xA681,0xA69B,0x2,-0x1}, {0xA723,0xA72F,0x2,-0x1}, {0xA733,0xA76F,0x2,-0x1}, {0xA77A,0xA77C,0x2,-0x1},
    {0xA77F,0xA787,0x2,-0x1}, {0xA78C,0xA78C,0x1,-0x1}, {0xA791,0xA793,0x2,-0x1}, {0xA794,0xA794,0x1,0x30},
    {0xA797,0xA7A9,0x2,-0x1}, {0xA7B5,0xA7C3,0x2,-0x1}, {0xA7C8,0xA7CA,0x2,-0x1}, {0xA7D1,0xA7D1,0x1,-0x1},
    {0xA7D7,0xA7D9,0x2,-0x1}, {0xA7F6,0xA7F6,0x1,-0x1}, {0xAB53,0xAB53,0x1,-0x3A0}, {0xAB70,0xABBF,0x1,-0x97D0},
    {0xFF41,0xFF5A,0x1,-0x20}, {0x10428,0x1044F,0x1,-0x28}, {0x104D8,0x104FB,0x1,-0x28}, {0x10597,0x105A1,0x1,-0x27},
    {0x105A3,0x105B1,0x1,-0x27}, {0x105B3,0x105B9,0x1,-0x27}, {0x105BB,0x105BC,0x1,-0x27},
    {0x10CC0,0x10CF2,0x1,-0x40}, {0x118C0,0x118DF,0x1,-0x20}, {0x16E60,0x16E7F,0x1,-0x20},
    {0x1E922,0x1E943,0x1,-0x22},
};


/* ---- character classes ---- */

enum { F_I = 1, F_M = 2, F_S = 4, F_X = 8, F_A = 16, F_U = 32 };
#define RX_INF 0x7fffffff
#define RX_MAXREPEAT 4294967295.0           /* Python's MAXREPEAT: counts at or above it are an error */
#define RX_STEP_LIMIT 200000000LL            /* machine steps per builtin call before we call it runaway */
#define RX_STACK_LIMIT (16LL << 20)          /* backtracking entries (16 bytes each) */
#define RX_MAX_DEPTH 200                     /* nesting of groups in a pattern */

static int tab2_has(const int32_t (*t)[2], int n, int32_t c) {
    int lo = 0, hi = n - 1;
    while (lo <= hi) {
        int m = (lo + hi) / 2;
        if (c < t[m][0]) hi = m - 1;
        else if (c > t[m][1]) lo = m + 1;
        else return 1;
    }
    return 0;
}
static int32_t tab4_map(const int32_t (*t)[4], int n, int32_t c) {
    int lo = 0, hi = n - 1, best = -1;
    while (lo <= hi) {
        int m = (lo + hi) / 2;
        if (t[m][0] <= c) { best = m; lo = m + 1; } else hi = m - 1;
    }
    if (best >= 0 && c <= t[best][1] && (c - t[best][0]) % t[best][2] == 0) return c + t[best][3];
    return c;
}
static int32_t rx_lower(int32_t c, int ascii) {
    if (c < 128) return (c >= 'A' && c <= 'Z') ? c + 32 : c;
    return ascii ? c : tab4_map(rx_lower_tab, NELEM(rx_lower_tab), c);
}
static int32_t rx_upper(int32_t c, int ascii) {
    if (c < 128) return (c >= 'a' && c <= 'z') ? c - 32 : c;
    return ascii ? c : tab4_map(rx_upper_tab, NELEM(rx_upper_tab), c);
}
static int rx_word(int32_t c, int ascii) {
    if (c < 128) return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
    return !ascii && tab2_has(rx_word_tab, NELEM(rx_word_tab), c);
}
static int rx_digit(int32_t c, int ascii) {
    if (c < 128) return c >= '0' && c <= '9';
    return !ascii && tab2_has(rx_digit_tab, NELEM(rx_digit_tab), c);
}
static int rx_space(int32_t c, int ascii) {
    if (c < 128) return c == ' ' || (c >= 9 && c <= 13) || (!ascii && c >= 28 && c <= 31);
    if (ascii) return 0;
    return c == 0x85 || c == 0xA0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200A) || c == 0x2028 || c == 0x2029 ||
           c == 0x202F || c == 0x205F || c == 0x3000;
}

enum { C_D = 1, C_ND = 2, C_W = 4, C_NW = 8, C_S = 16, C_NS = 32 };
typedef struct { int32_t lo, hi; } Rng;
typedef struct { int neg, cats, nr, cap; Rng *r; } Cls;

static int cls_has(const Cls *cl, int32_t c, int ascii) {
    for (int i = 0; i < cl->nr; i++) if (c >= cl->r[i].lo && c <= cl->r[i].hi) return 1;
    int k = cl->cats;
    if (k) {
        if ((k & C_D) && rx_digit(c, ascii)) return 1;
        if ((k & C_ND) && !rx_digit(c, ascii)) return 1;
        if ((k & C_W) && rx_word(c, ascii)) return 1;
        if ((k & C_NW) && !rx_word(c, ascii)) return 1;
        if ((k & C_S) && rx_space(c, ascii)) return 1;
        if ((k & C_NS) && !rx_space(c, ascii)) return 1;
    }
    return 0;
}
static int cls_match(const Cls *cl, int32_t c, int fl) {
    int a = (fl & F_A) != 0;
    int r = cls_has(cl, c, a);
    if (!r && (fl & F_I)) {
        int32_t l = rx_lower(c, a), u = rx_upper(c, a);
        r = (l != c && cls_has(cl, l, a)) || (u != c && cls_has(cl, u, a));
    }
    return r != cl->neg;
}

/* ---- pattern tree ---- */

enum { N_EMPTY, N_CHAR, N_ANY, N_CLASS, N_CAT, N_ALT, N_GROUP, N_REPEAT, N_AT, N_BREF, N_LOOK, N_ATOMIC, N_COND };
enum { AT_BOL, AT_EOL, AT_BOS, AT_EOS, AT_WB, AT_NWB };
typedef struct {
    int type, flags;
    int a, b, c;          /* CHAR a=code point; CLASS a=class; GROUP a=group (-1: not capturing); REPEAT a=min b=max
                             c=0 greedy/1 lazy/2 possessive; AT a=kind; BREF a=group; LOOK a=behind b=negative;
                             COND a=group */
    int x, y;             /* child nodes: GROUP/REPEAT/LOOK/ATOMIC x; COND x=yes y=no (-1) */
    int *kids, nk, capk;  /* CAT / ALT */
} Node;

typedef struct {
    const int32_t *p; int n, i;
    int flags;
    Node *nodes; int nn, capn;
    Cls *cls; int ncls, capcls;
    int ngroups, capg;
    char **names;         /* names[g]: group name (malloc'd) or NULL */
    int *open;            /* open[g]: group still being parsed */
    int *gnode;           /* gnode[g]: its GROUP node */
    char err[300];
    jmp_buf jb;
} P;

__attribute__((noreturn, format(printf, 2, 3))) static void perr(P *ps, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(ps->err, sizeof ps->err, fmt, ap);
    va_end(ap);
    longjmp(ps->jb, 1);
}
static void *xrealloc(void *p, size_t n) {
    void *q = realloc(p, n ? n : 1);
    if (!q) { fprintf(stderr, "vanta: out of memory\n"); abort(); }
    return q;
}
static int new_node(P *ps, int type) {
    if (ps->nn == ps->capn) { ps->capn = ps->capn ? ps->capn * 2 : 32; ps->nodes = xrealloc(ps->nodes, sizeof(Node) * (size_t)ps->capn); }
    Node *nd = &ps->nodes[ps->nn];
    memset(nd, 0, sizeof *nd);
    nd->type = type; nd->flags = ps->flags; nd->x = nd->y = -1;
    return ps->nn++;
}
static void add_kid(P *ps, int parent, int kid) {
    Node *nd = &ps->nodes[parent];
    if (nd->nk == nd->capk) { nd->capk = nd->capk ? nd->capk * 2 : 4; nd->kids = xrealloc(nd->kids, sizeof(int) * (size_t)nd->capk); }
    nd->kids[nd->nk++] = kid;
}
static int new_cls(P *ps) {
    if (ps->ncls == ps->capcls) { ps->capcls = ps->capcls ? ps->capcls * 2 : 8; ps->cls = xrealloc(ps->cls, sizeof(Cls) * (size_t)ps->capcls); }
    memset(&ps->cls[ps->ncls], 0, sizeof(Cls));
    return ps->ncls++;
}
static void cls_add(Cls *cl, int32_t lo, int32_t hi) {
    if (cl->nr == cl->cap) { cl->cap = cl->cap ? cl->cap * 2 : 8; cl->r = xrealloc(cl->r, sizeof(Rng) * (size_t)cl->cap); }
    cl->r[cl->nr].lo = lo; cl->r[cl->nr].hi = hi; cl->nr++;
}

static int peekc(P *ps) { return ps->i < ps->n ? ps->p[ps->i] : -1; }
static int getc_(P *ps) { return ps->i < ps->n ? ps->p[ps->i++] : -1; }
static int matchc(P *ps, int c) { if (ps->i < ps->n && ps->p[ps->i] == c) { ps->i++; return 1; } return 0; }
static int isdig(int c) { return c >= '0' && c <= '9'; }
static int isoct(int c) { return c >= '0' && c <= '7'; }
static int ishex(int c) { return isdig(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }
static int hexval(int c) { return isdig(c) ? c - '0' : (c | 32) - 'a' + 10; }
static int isasciiletter(int c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }

static int enc_utf8(char *o, int32_t c) {
    if (c < 0x80) { o[0] = (char)c; return 1; }
    if (c < 0x800) { o[0] = (char)(0xC0 | (c >> 6)); o[1] = (char)(0x80 | (c & 63)); return 2; }
    if (c < 0x10000) { o[0] = (char)(0xE0 | (c >> 12)); o[1] = (char)(0x80 | ((c >> 6) & 63)); o[2] = (char)(0x80 | (c & 63)); return 3; }
    o[0] = (char)(0xF0 | (c >> 18)); o[1] = (char)(0x80 | ((c >> 12) & 63)); o[2] = (char)(0x80 | ((c >> 6) & 63)); o[3] = (char)(0x80 | (c & 63));
    return 4;
}
/* decode UTF-8 into code points; offs (if given) gets each code point's byte offset plus a final entry */
static int32_t dec_utf8(const unsigned char *s, int64_t len, int32_t *out, int32_t *offs) {
    int32_t n = 0;
    int64_t i = 0;
    while (i < len) {
        unsigned c = s[i];
        int k = c < 0x80 ? 1 : (c >> 5) == 6 ? 2 : (c >> 4) == 14 ? 3 : (c >> 3) == 30 ? 4 : 1;
        if (i + k > len) k = 1;
        uint32_t cp = k == 1 ? c : k == 2 ? (c & 31) : k == 3 ? (c & 15) : (c & 7);
        for (int j = 1; j < k; j++) cp = (cp << 6) | (s[i + j] & 63);
        if (offs) offs[n] = (int32_t)i;
        out[n++] = (int32_t)cp;
        i += k;
    }
    if (offs) offs[n] = (int32_t)len;
    return n;
}
/* text of pattern characters [a, b) for error messages */
static const char *pslice(P *ps, int a, int b, char *buf, int cap) {
    int o = 0;
    for (int i = a; i < b && i < ps->n && o < cap - 5; i++) o += enc_utf8(buf + o, ps->p[i]);
    buf[o] = 0;
    return buf;
}

static int parse_alt(P *ps, int depth);
static int parse_seq_into(P *ps, int seq, int depth, int top_first);

static int lit_node(P *ps, int32_t c) { int k = new_node(ps, N_CHAR); ps->nodes[k].a = c; return k; }
static int cat_node(P *ps, int cats) {
    int k = new_node(ps, N_CLASS);
    int ci = new_cls(ps);
    ps->cls[ci].cats = cats;
    ps->nodes[k].a = ci;
    return k;
}
static int cat_of(int c) {
    switch (c) { case 'd': return C_D; case 'D': return C_ND; case 'w': return C_W; case 'W': return C_NW; case 's': return C_S; case 'S': return C_NS; }
    return 0;
}
static int32_t simple_escape(int c) {
    switch (c) { case 'a': return 7; case 'f': return 12; case 'n': return 10; case 'r': return 13; case 't': return 9; case 'v': return 11; case '\\': return '\\'; }
    return -1;
}
/* \x \u \U after the letter; start = index of the backslash */
static int32_t hex_escape(P *ps, int c, int start) {
    int need = c == 'x' ? 2 : c == 'u' ? 4 : 8;
    uint32_t v = 0;
    char buf[40];
    for (int k = 0; k < need; k++) {
        int h = peekc(ps);
        if (h < 0 || !ishex(h)) perr(ps, "incomplete escape %s at position %d", pslice(ps, start, ps->i, buf, sizeof buf), start);
        ps->i++;
        v = v * 16 + (uint32_t)hexval(h);
    }
    if (v > 0x10FFFF) perr(ps, "bad escape %s at position %d", pslice(ps, start, ps->i, buf, sizeof buf), start);
    return (int32_t)v;
}
static void check_backref(P *ps, int g, int start) {
    if (g > ps->ngroups) perr(ps, "invalid group reference %d at position %d", g, start + 1);
    if (ps->open[g]) perr(ps, "cannot refer to an open group at position %d", start);
}

/* an escape inside [...]: returns a code point, or -(category) for \d \w \s ... */
static int32_t class_escape(P *ps, int start) {
    int c = getc_(ps);
    char buf[40];
    if (c < 0) perr(ps, "bad escape (end of pattern) at position %d", start);
    if (c == 'b') return 8;
    int32_t e = simple_escape(c);
    if (e >= 0) return e;
    if (cat_of(c)) return -cat_of(c);
    if (c == 'x' || c == 'u' || c == 'U') return hex_escape(ps, c, start);
    if (c == 'N') perr(ps, "\\N{...} escapes aren't supported in native builds at position %d", start);
    if (isoct(c)) {
        int v = c - '0';
        for (int k = 0; k < 2 && isoct(peekc(ps)); k++) v = v * 8 + (getc_(ps) - '0');
        if (v > 0377) perr(ps, "octal escape value %s outside of range 0-0o377 at position %d", pslice(ps, start, ps->i, buf, sizeof buf), start);
        return v;
    }
    if (isdig(c) || isasciiletter(c)) perr(ps, "bad escape %s at position %d", pslice(ps, start, ps->i, buf, sizeof buf), start);
    return c;
}

static int parse_class(P *ps) {
    int start = ps->i - 1;
    int k = new_node(ps, N_CLASS);
    int ci = new_cls(ps);
    ps->nodes[k].a = ci;
    if (matchc(ps, '^')) ps->cls[ci].neg = 1;
    int first = ps->i;
    char b1[40], b2[40];
    for (;;) {
        int here = ps->i;
        int c = getc_(ps);
        if (c < 0) perr(ps, "unterminated character set at position %d", start);
        if (c == ']' && here != first) break;
        int32_t c1 = c == '\\' ? class_escape(ps, here) : c;
        int c1end = ps->i;
        if (matchc(ps, '-')) {
            int here2 = ps->i;
            int d = getc_(ps);
            if (d < 0) perr(ps, "unterminated character set at position %d", start);
            if (d == ']') {
                if (c1 < 0) ps->cls[ci].cats |= -c1; else cls_add(&ps->cls[ci], c1, c1);
                cls_add(&ps->cls[ci], '-', '-');
                break;
            }
            int32_t c2 = d == '\\' ? class_escape(ps, here2) : d;
            if (c1 < 0 || c2 < 0)
                perr(ps, "bad character range %s at position %d", pslice(ps, here, ps->i, b1, sizeof b1), here);
            if (c2 < c1)
                perr(ps, "bad character range %s at position %d", pslice(ps, here, ps->i, b2, sizeof b2), here);
            cls_add(&ps->cls[ci], c1, c2);
        } else {
            if (c1 < 0) ps->cls[ci].cats |= -c1; else cls_add(&ps->cls[ci], c1, c1);
        }
        (void)c1end;
    }
    return k;
}

static int parse_escape(P *ps) {
    int start = ps->i - 1;
    int c = getc_(ps);
    char buf[40];
    if (c < 0) perr(ps, "bad escape (end of pattern) at position %d", start);
    int k;
    switch (c) {
    case 'A': k = new_node(ps, N_AT); ps->nodes[k].a = AT_BOS; return k;
    case 'Z': k = new_node(ps, N_AT); ps->nodes[k].a = AT_EOS; return k;
    case 'b': k = new_node(ps, N_AT); ps->nodes[k].a = AT_WB; return k;
    case 'B': k = new_node(ps, N_AT); ps->nodes[k].a = AT_NWB; return k;
    case 'd': case 'D': case 'w': case 'W': case 's': case 'S': return cat_node(ps, cat_of(c));
    case 'x': case 'u': case 'U': return lit_node(ps, hex_escape(ps, c, start));
    case 'N': perr(ps, "\\N{...} escapes aren't supported in native builds at position %d", start);
    case '0': {
        int v = 0;
        for (int j = 0; j < 2 && isoct(peekc(ps)); j++) v = v * 8 + (getc_(ps) - '0');
        return lit_node(ps, v);
    }
    }
    if (isdig(c)) {
        int g = c - '0';
        if (isdig(peekc(ps))) {
            int d = getc_(ps);
            if (isoct(c) && isoct(d) && isoct(peekc(ps))) {
                int v = (c - '0') * 64 + (d - '0') * 8 + (getc_(ps) - '0');
                if (v > 0377) perr(ps, "octal escape value %s outside of range 0-0o377 at position %d", pslice(ps, start, ps->i, buf, sizeof buf), start);
                return lit_node(ps, v);
            }
            g = g * 10 + (d - '0');
        }
        check_backref(ps, g, start);
        k = new_node(ps, N_BREF);
        ps->nodes[k].a = g;
        return k;
    }
    int32_t e = simple_escape(c);
    if (e >= 0) return lit_node(ps, e);
    if (isasciiletter(c)) perr(ps, "bad escape %s at position %d", pslice(ps, start, ps->i, buf, sizeof buf), start);
    return lit_node(ps, c);
}

/* (?P<name>, (?P=name, (?(name): reads up to the terminator; returns a malloc'd UTF-8 name */
static char *parse_name(P *ps, int term, int *isnum, int *num) {
    int start = ps->i;
    while (ps->i < ps->n && ps->p[ps->i] != term) ps->i++;
    if (ps->i >= ps->n) {
        if (start == ps->n) perr(ps, "missing group name at position %d", start);
        perr(ps, "missing %c, unterminated name at position %d", term, start);
    }
    int end = ps->i++;
    if (end == start) perr(ps, "missing group name at position %d", start);
    char *name = malloc((size_t)(end - start) * 4 + 1);
    int o = 0;
    for (int i = start; i < end; i++) o += enc_utf8(name + o, ps->p[i]);
    name[o] = 0;
    *isnum = 1; *num = 0;
    for (int i = start; i < end; i++) {
        if (!isdig(ps->p[i])) { *isnum = 0; break; }
        if (*num < 100000000) *num = *num * 10 + (ps->p[i] - '0');
    }
    if (*isnum) return name;
    int ok = 1;
    for (int i = start; i < end; i++) {
        int32_t c = ps->p[i];
        if (!(rx_word(c, 0) && (i > start || !rx_digit(c, 0)))) { ok = 0; break; }
    }
    if (!ok) {
        char msg[200];
        snprintf(msg, sizeof msg, "bad character in group name '%s' at position %d", name, start);
        free(name);
        perr(ps, "%s", msg);
    }
    return name;
}
static int find_name(P *ps, const char *name) {
    for (int g = 1; g <= ps->ngroups; g++) if (ps->names[g] && strcmp(ps->names[g], name) == 0) return g;
    return 0;
}
static int new_group(P *ps) {
    int g = ++ps->ngroups;
    if (g >= ps->capg) {
        int nc = ps->capg ? ps->capg * 2 : 16;
        while (nc <= g) nc *= 2;
        ps->names = xrealloc(ps->names, sizeof(char *) * (size_t)nc);
        ps->open = xrealloc(ps->open, sizeof(int) * (size_t)nc);
        ps->gnode = xrealloc(ps->gnode, sizeof(int) * (size_t)nc);
        for (int i = ps->capg; i < nc; i++) { ps->names[i] = NULL; ps->open[i] = 0; ps->gnode[i] = -1; }
        ps->capg = nc;
    }
    ps->open[g] = 1;
    return g;
}
static void expect_close(P *ps, int start) {
    if (!matchc(ps, ')')) perr(ps, "missing ), unterminated subpattern at position %d", start);
}

/* min and max width (in characters) a node can match; max RX_INF = unbounded */
static void width(P *ps, int k, int64_t *lo, int64_t *hi) {
    Node *nd = &ps->nodes[k];
    int64_t a, b, c, d;
    switch (nd->type) {
    case N_CHAR: case N_ANY: case N_CLASS: *lo = *hi = 1; return;
    case N_CAT:
        *lo = *hi = 0;
        for (int i = 0; i < nd->nk; i++) {
            width(ps, nd->kids[i], &a, &b);
            *lo += a; *hi = (*hi >= RX_INF || b >= RX_INF) ? RX_INF : *hi + b;
            if (*lo > RX_INF) *lo = RX_INF;
        }
        return;
    case N_ALT:
        *lo = RX_INF; *hi = 0;
        for (int i = 0; i < nd->nk; i++) {
            width(ps, nd->kids[i], &a, &b);
            if (a < *lo) *lo = a;
            if (b > *hi) *hi = b;
        }
        if (nd->nk == 0) *lo = 0;
        return;
    case N_GROUP: case N_ATOMIC: width(ps, nd->x, lo, hi); return;
    case N_REPEAT:
        width(ps, nd->x, &a, &b);
        *lo = a * nd->a; if (*lo > RX_INF) *lo = RX_INF;
        *hi = (b == 0) ? 0 : (b >= RX_INF || nd->b >= RX_INF) ? RX_INF : b * nd->b;
        if (*hi > RX_INF) *hi = RX_INF;
        return;
    case N_BREF:
        if (ps->gnode[nd->a] >= 0) { width(ps, ps->gnode[nd->a], lo, hi); return; }
        *lo = 0; *hi = RX_INF; return;
    case N_COND:
        width(ps, nd->x, &a, &b);
        if (nd->y >= 0) width(ps, nd->y, &c, &d); else c = d = 0;
        *lo = a < c ? a : c; *hi = b > d ? b : d;
        return;
    default: *lo = *hi = 0; return;
    }
}

/* after '(' */
static int parse_group(P *ps, int depth, int at_start) {
    int start = ps->i - 1;
    char buf[40];
    if (depth > RX_MAX_DEPTH) perr(ps, "too many nested groups at position %d", start);
    if (!matchc(ps, '?')) {
        int g = new_group(ps);
        int k = new_node(ps, N_GROUP);
        ps->nodes[k].a = g;
        int child = parse_alt(ps, depth + 1);
        expect_close(ps, start);
        ps->nodes[k].x = child;
        ps->open[g] = 0;
        ps->gnode[g] = k;
        return k;
    }
    int c = getc_(ps);
    if (c < 0) perr(ps, "unexpected end of pattern at position %d", ps->i);
    int isnum, num;
    if (c == 'P') {
        if (matchc(ps, '<')) {
            char *name = parse_name(ps, '>', &isnum, &num);
            if (isnum) {
                char msg[200];
                snprintf(msg, sizeof msg, "bad character in group name '%s' at position %d", name, start + 4);
                free(name);
                perr(ps, "%s", msg);
            }
            int old = find_name(ps, name);
            if (old) {
                char msg[200];
                snprintf(msg, sizeof msg, "redefinition of group name '%s' as group %d; was group %d", name, ps->ngroups + 1, old);
                free(name);
                perr(ps, "%s", msg);
            }
            int g = new_group(ps);
            ps->names[g] = name;
            int k = new_node(ps, N_GROUP);
            ps->nodes[k].a = g;
            int child = parse_alt(ps, depth + 1);
            expect_close(ps, start);
            ps->nodes[k].x = child;
            ps->open[g] = 0;
            ps->gnode[g] = k;
            return k;
        }
        if (matchc(ps, '=')) {
            char *name = parse_name(ps, ')', &isnum, &num);
            int g = isnum ? 0 : find_name(ps, name);
            if (!g) {
                char msg[200];
                snprintf(msg, sizeof msg, "unknown group name '%s' at position %d", name, start + 4);
                free(name);
                perr(ps, "%s", msg);
            }
            free(name);
            if (ps->open[g]) perr(ps, "cannot refer to an open group at position %d", start);
            int k = new_node(ps, N_BREF);
            ps->nodes[k].a = g;
            return k;
        }
        int d = peekc(ps);
        if (d < 0) perr(ps, "unexpected end of pattern at position %d", ps->i);
        perr(ps, "unknown extension ?P%s at position %d", pslice(ps, ps->i, ps->i + 1, buf, sizeof buf), start + 1);
    }
    if (c == ':' || c == '>') {
        int k = new_node(ps, c == ':' ? N_GROUP : N_ATOMIC);
        ps->nodes[k].a = -1;
        int child = parse_alt(ps, depth + 1);
        expect_close(ps, start);
        ps->nodes[k].x = child;
        return k;
    }
    if (c == '#') {
        while (ps->i < ps->n && ps->p[ps->i] != ')') ps->i++;
        if (ps->i >= ps->n) perr(ps, "missing ), unterminated comment at position %d", start);
        ps->i++;
        return -1;
    }
    if (c == '=' || c == '!' || c == '<') {
        int behind = 0;
        if (c == '<') {
            int d = getc_(ps);
            if (d < 0) perr(ps, "unexpected end of pattern at position %d", ps->i);
            if (d != '=' && d != '!') perr(ps, "unknown extension ?<%s at position %d", pslice(ps, ps->i - 1, ps->i, buf, sizeof buf), start + 1);
            behind = 1; c = d;
        }
        int k = new_node(ps, N_LOOK);
        ps->nodes[k].a = behind;
        ps->nodes[k].b = c == '!';
        int child = parse_alt(ps, depth + 1);
        expect_close(ps, start);
        ps->nodes[k].x = child;
        if (behind) {
            int64_t lo, hi;
            width(ps, child, &lo, &hi);
            if (lo != hi || hi >= RX_INF) perr(ps, "look-behind requires fixed-width pattern");
            ps->nodes[k].c = (int)lo;
        }
        return k;
    }
    if (c == '(') {
        char *name = parse_name(ps, ')', &isnum, &num);
        int g;
        if (isnum) {
            g = num;
            if (g == 0) { free(name); perr(ps, "bad group number at position %d", start + 3); }
            if (g > ps->ngroups) { free(name); perr(ps, "invalid group reference %d at position %d", g, start + 3); }
        } else {
            g = find_name(ps, name);
            if (!g) {
                char msg[200];
                snprintf(msg, sizeof msg, "unknown group name '%s' at position %d", name, start + 3);
                free(name);
                perr(ps, "%s", msg);
            }
        }
        free(name);
        int k = new_node(ps, N_COND);
        ps->nodes[k].a = g;
        /* yes|no: each side is a plain sequence; a third branch is an error */
        int yes = new_node(ps, N_CAT), no = -1;
        parse_seq_into(ps, yes, depth + 1, 0);
        if (matchc(ps, '|')) {
            no = new_node(ps, N_CAT);
            parse_seq_into(ps, no, depth + 1, 0);
            if (peekc(ps) == '|') perr(ps, "conditional backref with more than two branches at position %d", ps->i);
        }
        expect_close(ps, start);
        ps->nodes[k].x = yes;
        ps->nodes[k].y = no;
        return k;
    }
    if (strchr("aiLmsux-", c)) {
        int add = 0, del = 0, *cur = &add;
        ps->i--;
        for (;;) {
            int d = getc_(ps);
            if (d < 0) perr(ps, "missing -, : or ) at position %d", ps->i);
            if (d == ')' || d == ':') { c = d; break; }
            if (d == '-') {
                if (cur == &del) perr(ps, "unknown flag at position %d", ps->i - 1);
                cur = &del;
                continue;
            }
            int f = d == 'a' ? F_A : d == 'i' ? F_I : d == 'm' ? F_M : d == 's' ? F_S : d == 'u' ? F_U : d == 'x' ? F_X : 0;
            if (d == 'L') perr(ps, "bad inline flags: cannot use 'L' flag with a str pattern at position %d", ps->i - 1);
            if (!f) perr(ps, isasciiletter(d) ? "unknown flag at position %d" : "missing -, : or ) at position %d", ps->i - 1);
            if (cur == &del && (f == F_A || f == F_U)) perr(ps, "bad inline flags: cannot turn off flags 'a', 'u' and 'L' at position %d", ps->i - 1);
            *cur |= f;
        }
        if ((add & F_A) && (add & F_U)) perr(ps, "bad inline flags: flags 'a', 'u' and 'L' are incompatible at position %d", ps->i - 1);
        if (c == ')') {
            if (del) perr(ps, "missing : at position %d", ps->i - 1);
            if (!at_start) perr(ps, "global flags not at the start of the expression at position %d", start);
            ps->flags |= add;
            if (add & F_U) ps->flags &= ~F_A;
            return -1;
        }
        int save = ps->flags;
        ps->flags = (ps->flags | add) & ~del;
        if (add & F_A) ps->flags &= ~F_U;
        if (add & F_U) ps->flags &= ~F_A;
        int k = new_node(ps, N_GROUP);
        ps->nodes[k].a = -1;
        int child = parse_alt(ps, depth + 1);
        expect_close(ps, start);
        ps->flags = save;
        ps->nodes[k].x = child;
        return k;
    }
    perr(ps, "unknown extension ?%s at position %d", pslice(ps, ps->i - 1, ps->i, buf, sizeof buf), start + 1);
}

/* parse items into the CAT node `seq` until '|' or ')' or the end */
static int parse_seq_into(P *ps, int seq, int depth, int top_first) {
    int last = -1;          /* index of the last item in seq (for quantifiers) */
    int last_is_rep = 0;
    for (;;) {
        int c = peekc(ps);
        if (c < 0 || c == '|' || c == ')') break;
        int here = ps->i;
        ps->i++;
        if (ps->flags & F_X) {
            if (c == ' ' || (c >= 9 && c <= 13)) continue;
            if (c == '#') { while (ps->i < ps->n && ps->p[ps->i] != '\n') ps->i++; continue; }
        }
        int atom = -1;
        if (c == '*' || c == '+' || c == '?' || c == '{') {
            int64_t mn, mx;
            if (c == '{') {
                if (peekc(ps) == '}') { atom = lit_node(ps, '{'); goto append; }
                int64_t lo = -1, hi = -1;
                int j = ps->i;
                while (j < ps->n && isdig(ps->p[j])) { lo = (lo < 0 ? 0 : lo) * 10 + (ps->p[j] - '0'); if (lo > 1e10) lo = (int64_t)1e10; j++; }
                if (j < ps->n && ps->p[j] == ',') {
                    j++;
                    while (j < ps->n && isdig(ps->p[j])) { hi = (hi < 0 ? 0 : hi) * 10 + (ps->p[j] - '0'); if (hi > 1e10) hi = (int64_t)1e10; j++; }
                } else hi = lo;
                if (j >= ps->n || ps->p[j] != '}') { atom = lit_node(ps, '{'); goto append; }
                ps->i = j + 1;
                mn = lo < 0 ? 0 : lo;
                mx = hi < 0 ? RX_INF : hi;
                if ((double)mn >= RX_MAXREPEAT || (hi >= 0 && (double)hi >= RX_MAXREPEAT)) perr(ps, "the repetition number is too large at position %d", here + 1);
                if (mx < mn) perr(ps, "min repeat greater than max repeat at position %d", here + 1);
                if (mn > RX_INF - 1) mn = RX_INF - 1;
                if (mx > RX_INF) mx = RX_INF;
            } else {
                mn = c == '+' ? 1 : 0;
                mx = c == '?' ? 1 : RX_INF;
            }
            if (last < 0 || ps->nodes[ps->nodes[seq].kids[last]].type == N_AT) perr(ps, "nothing to repeat at position %d", here);
            if (last_is_rep) perr(ps, "multiple repeat at position %d", here);
            int k = new_node(ps, N_REPEAT);
            ps->nodes[k].a = (int)mn;
            ps->nodes[k].b = (int)mx;
            ps->nodes[k].c = matchc(ps, '?') ? 1 : matchc(ps, '+') ? 2 : 0;
            ps->nodes[k].x = ps->nodes[seq].kids[last];
            ps->nodes[seq].kids[last] = k;
            last_is_rep = 1;
            continue;
        }
        switch (c) {
        case '[': atom = parse_class(ps); break;
        case '.': atom = new_node(ps, N_ANY); break;
        case '^': atom = new_node(ps, N_AT); ps->nodes[atom].a = AT_BOL; break;
        case '$': atom = new_node(ps, N_AT); ps->nodes[atom].a = AT_EOL; break;
        case '\\': atom = parse_escape(ps); break;
        case '(':
            atom = parse_group(ps, depth, top_first && ps->nodes[seq].nk == 0);
            if (atom < 0) continue;
            break;
        default: atom = lit_node(ps, c); break;
        }
    append:
        add_kid(ps, seq, atom);
        last = ps->nodes[seq].nk - 1;
        last_is_rep = 0;
    }
    return seq;
}

static int parse_alt(P *ps, int depth) {
    int first = new_node(ps, N_CAT);
    parse_seq_into(ps, first, depth, depth == 0);
    if (peekc(ps) != '|') return first;
    int alt = new_node(ps, N_ALT);
    add_kid(ps, alt, first);
    while (matchc(ps, '|')) {
        int s = new_node(ps, N_CAT);
        parse_seq_into(ps, s, depth, 0);
        add_kid(ps, alt, s);
    }
    return alt;
}

/* ---- compiled program ---- */

enum { O_CHAR, O_ANY, O_CLASS, O_SPLIT, O_JMP, O_SAVE, O_AT, O_BREF, O_REPSTART, O_REPTEST, O_MARK, O_REPEND, O_REP1,
       O_LOOK, O_ATOMIC, O_SUBEND, O_COND, O_MATCH };
typedef struct { uint8_t op, fl; int32_t a, b, c, d, e; } Inst;
/* CHAR a=char b=lower c=upper; CLASS a=class; SPLIT try a, then b; JMP a; SAVE a=register; AT a=kind; BREF a=group;
 * REPSTART a=r (count r; mark r+1 = where the latest optional iteration started, as sre's last_ptr); REPTEST a=r b=min c=max d=greedy e=exit; MARK a=r+1; REPEND a=r b=min c=test
 * d=exit; REP1 a=min b=max c=0 greedy/1 lazy/2 possessive (the one-character matcher follows, then the rest);
 * LOOK a=behind b=negative c=width d=after; ATOMIC d=after; COND a=group b=else */

typedef struct Prog {
    Inst *code; int ncode, capcode;
    Cls *cls; int ncls;
    int ngroups, nregs;
    char **names;
    int32_t first;        /* a character every match must start with (no flags), or -1 */
    char *key; int64_t keylen;
} Prog;

static int emit(Prog *pg, int op, int fl) {
    if (pg->ncode == pg->capcode) { pg->capcode = pg->capcode ? pg->capcode * 2 : 64; pg->code = xrealloc(pg->code, sizeof(Inst) * (size_t)pg->capcode); }
    Inst *in = &pg->code[pg->ncode];
    memset(in, 0, sizeof *in);
    in->op = (uint8_t)op; in->fl = (uint8_t)fl;
    return pg->ncode++;
}

static void comp(P *ps, Prog *pg, int k) {
    Node *nd = &ps->nodes[k];
    int fl = nd->flags, i;
    switch (nd->type) {
    case N_EMPTY: break;
    case N_CHAR: {
        i = emit(pg, O_CHAR, fl);
        int a = (fl & F_A) != 0;
        pg->code[i].a = nd->a; pg->code[i].b = rx_lower(nd->a, a); pg->code[i].c = rx_upper(nd->a, a);
        break;
    }
    case N_ANY: emit(pg, O_ANY, fl); break;
    case N_CLASS: i = emit(pg, O_CLASS, fl); pg->code[i].a = nd->a; break;
    case N_CAT: for (int j = 0; j < nd->nk; j++) comp(ps, pg, ps->nodes[k].kids[j]); break;
    case N_ALT: {
        int nk = nd->nk;
        int *jumps = malloc(sizeof(int) * (size_t)nk);
        for (int j = 0; j < nk; j++) {
            if (j < nk - 1) {
                int s = emit(pg, O_SPLIT, 0);
                pg->code[s].a = s + 1;
                comp(ps, pg, ps->nodes[k].kids[j]);
                jumps[j] = emit(pg, O_JMP, 0);
                pg->code[s].b = pg->ncode;
            } else comp(ps, pg, ps->nodes[k].kids[j]);
        }
        for (int j = 0; j < nk - 1; j++) pg->code[jumps[j]].a = pg->ncode;
        free(jumps);
        break;
    }
    case N_GROUP:
        if (nd->a < 0) { comp(ps, pg, nd->x); break; }
        i = emit(pg, O_SAVE, 0); pg->code[i].a = 2 * nd->a;
        comp(ps, pg, ps->nodes[k].x);
        i = emit(pg, O_SAVE, 0); pg->code[i].a = 2 * ps->nodes[k].a + 1;
        break;
    case N_REPEAT: {
        int mn = nd->a, mx = nd->b, mode = nd->c, child = nd->x;
        if (mx == 0) break;
        int ct = ps->nodes[child].type;
        if (ct == N_CHAR || ct == N_ANY || ct == N_CLASS) {
            i = emit(pg, O_REP1, 0);
            pg->code[i].a = mn; pg->code[i].b = mx; pg->code[i].c = mode;
            comp(ps, pg, child);
            break;
        }
        int at = -1;
        if (mode == 2) at = emit(pg, O_ATOMIC, 0);
        if (mn == 0 && mx == 1) {
            int s = emit(pg, O_SPLIT, 0);
            comp(ps, pg, child);
            if (mode == 1) { pg->code[s].a = pg->ncode; pg->code[s].b = s + 1; }
            else { pg->code[s].a = s + 1; pg->code[s].b = pg->ncode; }
        } else {
            int r = pg->nregs; pg->nregs += 2;
            i = emit(pg, O_REPSTART, 0); pg->code[i].a = r;
            int t = emit(pg, O_REPTEST, 0);
            pg->code[t].a = r; pg->code[t].b = mn; pg->code[t].c = mx; pg->code[t].d = mode != 1;
            i = emit(pg, O_MARK, 0); pg->code[i].a = r + 1;
            comp(ps, pg, child);
            int e = emit(pg, O_REPEND, 0);
            pg->code[e].a = r; pg->code[e].b = mn; pg->code[e].c = t;
            pg->code[t].e = pg->code[e].d = pg->ncode;
        }
        if (at >= 0) { emit(pg, O_SUBEND, 0); pg->code[at].d = pg->ncode; }
        break;
    }
    case N_AT: i = emit(pg, O_AT, fl); pg->code[i].a = nd->a; break;
    case N_BREF: i = emit(pg, O_BREF, fl); pg->code[i].a = nd->a; break;
    case N_LOOK: {
        int l = emit(pg, O_LOOK, 0);
        pg->code[l].a = nd->a; pg->code[l].b = nd->b; pg->code[l].c = nd->c;
        comp(ps, pg, nd->x);
        emit(pg, O_SUBEND, 0);
        pg->code[l].d = pg->ncode;
        break;
    }
    case N_ATOMIC: {
        int l = emit(pg, O_ATOMIC, 0);
        comp(ps, pg, nd->x);
        emit(pg, O_SUBEND, 0);
        pg->code[l].d = pg->ncode;
        break;
    }
    case N_COND: {
        int c = emit(pg, O_COND, 0);
        pg->code[c].a = nd->a;
        int yes = nd->x, no = nd->y;
        comp(ps, pg, yes);
        int j = emit(pg, O_JMP, 0);
        pg->code[c].b = pg->ncode;
        if (no >= 0) comp(ps, pg, no);
        pg->code[j].a = pg->ncode;
        break;
    }
    }
}

static void prog_free(Prog *pg) {
    if (!pg) return;
    free(pg->code);
    for (int i = 0; i < pg->ncls; i++) free(pg->cls[i].r);
    free(pg->cls);
    if (pg->names) for (int g = 0; g <= pg->ngroups; g++) free(pg->names[g]);
    free(pg->names);
    free(pg->key);
    free(pg);
}

/* compile a pattern; on error returns NULL with the message in err */
static Prog *rx_compile(const char *pat, int64_t plen, char *err, size_t errcap) {
    P ps;
    memset(&ps, 0, sizeof ps);
    int32_t *cps = malloc(sizeof(int32_t) * (size_t)(plen + 1));
    ps.p = cps;
    ps.n = dec_utf8((const unsigned char *)pat, plen, cps, NULL);
    ps.flags = F_U;
    new_group(&ps); ps.ngroups = 0; ps.open[0] = 0;     /* slot 0 = the whole match */
    Prog *pg = NULL;
    if (setjmp(ps.jb) == 0) {
        int root = parse_alt(&ps, 0);
        if (ps.i < ps.n) perr(&ps, "unbalanced parenthesis at position %d", ps.i);
        /* flags given at the start apply to the whole pattern (Python re-parses with them) */
        pg = calloc(1, sizeof(Prog));
        pg->ngroups = ps.ngroups;
        pg->nregs = 2 * (ps.ngroups + 1);
        comp(&ps, pg, root);
        emit(pg, O_MATCH, 0);
        pg->cls = ps.cls; pg->ncls = ps.ncls; ps.cls = NULL; ps.ncls = 0;
        pg->names = calloc((size_t)ps.ngroups + 1, sizeof(char *));
        for (int g = 1; g <= ps.ngroups; g++) { pg->names[g] = ps.names[g]; ps.names[g] = NULL; }
        pg->first = (pg->code[0].op == O_CHAR && !(pg->code[0].fl & F_I)) ? pg->code[0].a : -1;
    } else {
        snprintf(err, errcap, "%s", ps.err);
    }
    for (int k = 0; k < ps.nn; k++) free(ps.nodes[k].kids);
    free(ps.nodes);
    for (int i = 0; i < ps.ncls; i++) free(ps.cls[i].r);
    free(ps.cls);
    for (int g = 0; g < ps.capg; g++) free(ps.names[g]);
    free(ps.names); free(ps.open); free(ps.gnode);
    free(cps);
    return pg;
}

/* ---- the backtracking machine ---- */

enum { B_BRANCH, B_RESTORE, B_REP1G, B_REP1L };
typedef struct { int32_t k, pc, pos, v; } BT;

/* scratch buffers, reused across calls (only one thread runs Vanta code at a time, and no builtin here calls back
 * into Vanta), so an error that longjmps out never leaks them */
static BT *bt; static int64_t btcap;
static int32_t *subj, *offs; static int64_t subjcap;
static int32_t *regs; static int64_t regcap;

typedef struct {
    const Prog *p;
    const int32_t *s; int32_t n;
    int64_t sp, steps;
    int32_t sstart; int must_adv;
} M;

__attribute__((noreturn)) static void too_long(void) {
    vrt_fail("that pattern takes too long to match (too much backtracking)");
}
static inline void push(M *m, int k, int pc, int pos, int v) {
    if (m->sp == btcap) {
        if (btcap >= RX_STACK_LIMIT) vrt_fail("that pattern needs too much memory to match (too much backtracking)");
        btcap = btcap ? btcap * 2 : 1024;
        bt = xrealloc(bt, sizeof(BT) * (size_t)btcap);
    }
    BT *t = &bt[m->sp++];
    t->k = k; t->pc = pc; t->pos = pos; t->v = v;
}
static inline void setr(M *m, int r, int32_t v) {
    if (regs[r] == v) return;
    push(m, B_RESTORE, r, 0, regs[r]);
    regs[r] = v;
}
static inline int one(const Prog *p, const Inst *in, int32_t c) {
    switch (in->op) {
    case O_CHAR: return c == in->a || ((in->fl & F_I) && (rx_lower(c, in->fl & F_A) == in->b || rx_upper(c, in->fl & F_A) == in->c));
    case O_ANY: return c != '\n' || (in->fl & F_S);
    default: return cls_match(&p->cls[in->a], c, in->fl);
    }
}
static int at_ok(const M *m, const Inst *in, int32_t pos) {
    const int32_t *s = m->s; int32_t n = m->n;
    int a = (in->fl & F_A) != 0;
    switch (in->a) {
    case AT_BOL: return pos == 0 || ((in->fl & F_M) && s[pos - 1] == '\n');
    case AT_EOL: return (in->fl & F_M) ? (pos == n || s[pos] == '\n') : (pos == n || (pos == n - 1 && s[pos] == '\n'));
    case AT_BOS: return pos == 0;
    case AT_EOS: return pos == n;
    default: {
        if (n == 0) return 0;
        int before = pos > 0 && rx_word(s[pos - 1], a), after = pos < n && rx_word(s[pos], a);
        return in->a == AT_WB ? before != after : before == after;
    }
    }
}
static void keep_restores(M *m, int64_t base) {   /* a lookaround/atomic body succeeded: drop its choice points */
    int64_t j = base;
    for (int64_t i = base; i < m->sp; i++) if (bt[i].k == B_RESTORE) bt[j++] = bt[i];
    m->sp = j;
}
static void unwind(M *m, int64_t base) {
    while (m->sp > base) { BT *t = &bt[--m->sp]; if (t->k == B_RESTORE) regs[t->pc] = t->v; }
}

static int run(M *m, int pc, int32_t pos, int64_t base, int32_t *endpos) {
    const Inst *code = m->p->code;
    const int32_t *s = m->s;
    int32_t n = m->n;
    for (;;) {
        if (++m->steps > RX_STEP_LIMIT) too_long();
        const Inst *in = &code[pc];
        switch (in->op) {
        case O_CHAR: case O_ANY: case O_CLASS:
            if (pos < n && one(m->p, in, s[pos])) { pos++; pc++; continue; }
            goto fail;
        case O_SPLIT: push(m, B_BRANCH, in->b, pos, 0); pc = in->a; continue;
        case O_JMP: pc = in->a; continue;
        case O_SAVE: setr(m, in->a, pos); pc++; continue;
        case O_AT: if (at_ok(m, in, pos)) { pc++; continue; } goto fail;
        case O_BREF: {
            int32_t a = regs[2 * in->a], b = regs[2 * in->a + 1];
            if (a < 0 || b < 0) goto fail;
            int32_t len = b - a;
            if (len > n - pos) goto fail;
            int asc = (in->fl & F_A) != 0;
            for (int32_t i = 0; i < len; i++) {
                int32_t x = s[a + i], y = s[pos + i];
                if (x != y && !((in->fl & F_I) && (rx_lower(x, asc) == rx_lower(y, asc) || rx_upper(x, asc) == rx_upper(y, asc)))) goto fail;
            }
            m->steps += len;
            pos += len; pc++;
            continue;
        }
        case O_REPSTART: setr(m, in->a, 0); setr(m, in->a + 1, -1); pc++; continue;
        case O_REPTEST: {
            int32_t c = regs[in->a];
            if (c < in->b) { pc += 2; continue; }      /* a required iteration: no empty-iteration check (skip MARK) */
            if (c >= in->c) { pc = in->e; continue; }
            if (in->d) { push(m, B_BRANCH, in->e, pos, 0); pc++; }
            else { push(m, B_BRANCH, pc + 1, pos, 0); pc = in->e; }
            continue;
        }
        case O_MARK: setr(m, in->a, pos); pc++; continue;
        case O_REPEND: {
            int32_t c = regs[in->a] + 1;
            setr(m, in->a, c);
            pc = (c >= in->b && pos == regs[in->a + 1]) ? in->d : in->c;
            continue;
        }
        case O_REP1: {
            const Inst *mi = &code[pc + 1];
            int64_t lim64 = (int64_t)pos + in->b;
            int32_t lim = lim64 > n ? n : (int32_t)lim64;
            int32_t q = pos;
            if (in->c != 1) {
                while (q < lim && one(m->p, mi, s[q])) q++;
                m->steps += q - pos;
                if (q - pos < in->a) goto fail;
                if (in->c == 0 && q - pos > in->a) push(m, B_REP1G, pc + 2, q, pos + in->a);
            } else {
                int32_t want = pos + in->a;
                while (q < want) { if (q >= n || !one(m->p, mi, s[q])) goto fail; q++; }
                m->steps += q - pos;
                if (q < lim) push(m, B_REP1L, pc + 2, q, lim);
            }
            pos = q; pc += 2;
            continue;
        }
        case O_LOOK: {
            int64_t b0 = m->sp;
            int32_t e = 0;
            int ok;
            if (in->a) {
                int32_t st = pos - in->c;
                ok = st >= 0 && run(m, pc + 1, st, b0, &e);
                if (ok && e != pos) { unwind(m, b0); ok = 0; }
            } else ok = run(m, pc + 1, pos, b0, &e);
            if (ok) {
                if (in->b) { unwind(m, b0); goto fail; }
                keep_restores(m, b0);
            } else if (!in->b) goto fail;
            pc = in->d;
            continue;
        }
        case O_ATOMIC: {
            int64_t b0 = m->sp;
            int32_t e = 0;
            if (!run(m, pc + 1, pos, b0, &e)) goto fail;
            keep_restores(m, b0);
            pos = e; pc = in->d;
            continue;
        }
        case O_SUBEND: *endpos = pos; return 1;
        case O_COND: pc = (regs[2 * in->a] >= 0 && regs[2 * in->a + 1] >= 0) ? pc + 1 : in->b; continue;
        case O_MATCH:
            if (m->must_adv && pos == m->sstart) goto fail;
            *endpos = pos;
            return 1;
        }
    fail:
        for (;;) {
            if (m->sp <= base) return 0;
            BT *t = &bt[m->sp - 1];
            if (t->k == B_RESTORE) { regs[t->pc] = t->v; m->sp--; continue; }
            if (t->k == B_BRANCH) { pc = t->pc; pos = t->pos; m->sp--; break; }
            if (t->k == B_REP1G) {
                pos = t->pos - 1; pc = t->pc;
                if (pos <= t->v) m->sp--; else t->pos = pos;
                break;
            }
            /* B_REP1L: take one more character */
            {
                int32_t q = t->pos;
                if (q >= t->v || !one(m->p, &code[t->pc - 1], s[q])) { m->sp--; continue; }
                q++;
                pc = t->pc; pos = q;
                if (q >= t->v) m->sp--; else t->pos = q;
                break;
            }
        }
    }
}

static void regs_reset(const Prog *p) {
    for (int i = 0; i < p->nregs; i++) regs[i] = -1;
}
/* find the next match at or after `from`; group spans are left in regs */
static int rx_search(M *m, int32_t from, int32_t *ms, int32_t *me) {
    const Prog *p = m->p;
    regs_reset(p);
    m->sp = 0;
    m->sstart = from;
    for (int32_t st = from; st <= m->n; st++) {
        if (p->first >= 0) {
            while (st < m->n && m->s[st] != p->first) st++;
            if (st >= m->n) return 0;
        }
        int32_t e;
        if (run(m, 0, st, 0, &e)) {
            m->sp = 0;
            *ms = st; *me = e;
            return 1;
        }
    }
    return 0;
}

/* ---- pattern cache and argument plumbing ---- */

#define RX_CACHE 16
static Prog *cache[RX_CACHE];
static int cache_next;

static Prog *get_prog(V pat) {
    VStr *ps = AS_STR(pat);
    for (int i = 0; i < RX_CACHE; i++)
        if (cache[i] && cache[i]->keylen == ps->len && memcmp(cache[i]->key, ps->data, (size_t)ps->len) == 0) return cache[i];
    char err[400];
    Prog *pg = rx_compile(ps->data, ps->len, err, sizeof err);
    if (!pg) vrt_fail("that pattern is not valid: %s", err);
    pg->key = malloc((size_t)ps->len + 1);
    memcpy(pg->key, ps->data, (size_t)ps->len);
    pg->keylen = ps->len;
    prog_free(cache[cache_next]);
    cache[cache_next] = pg;
    cache_next = (cache_next + 1) % RX_CACHE;
    return pg;
}

/* set up a machine over `text` (decoded into the scratch buffers) */
static void setup(M *m, const Prog *p, VStr *text) {
    if (text->len + 1 > subjcap) {
        subjcap = text->len + 1;
        subj = xrealloc(subj, sizeof(int32_t) * (size_t)subjcap);
        offs = xrealloc(offs, sizeof(int32_t) * (size_t)subjcap);
    }
    if (btcap > (1 << 20)) { free(bt); bt = NULL; btcap = 0; }    /* don't hold on to a huge stack from an earlier call */
    if (p->nregs > regcap) { regcap = p->nregs; regs = xrealloc(regs, sizeof(int32_t) * (size_t)regcap); }
    memset(m, 0, sizeof *m);
    m->p = p;
    m->s = subj;
    m->n = dec_utf8((const unsigned char *)text->data, text->len, subj, offs);
}
static V sub_text(VStr *text, int32_t a, int32_t b) { return vrt_str(text->data + offs[a], offs[b] - offs[a]); }
static V group_text(VStr *text, int g) {
    int32_t a = regs[2 * g], b = regs[2 * g + 1];
    if (a < 0 || b < 0) return VNIL;
    return sub_text(text, a, b);
}

/* ---- the builtins ---- */

static V b_matches(int argc, V *a) {
    NEED(2, "matches");
    V text = vrt_display(a[0]), pat = vrt_display(a[1]);
    Prog *p = get_prog(pat);
    M m;
    setup(&m, p, AS_STR(text));
    int32_t ms, me;
    return VB(rx_search(&m, 0, &ms, &me));
}

static V b_find_all(int argc, V *a) {
    NEED(2, "find_all");
    V text = vrt_display(a[0]), pat = vrt_display(a[1]);
    Prog *p = get_prog(pat);
    M m;
    setup(&m, p, AS_STR(text));
    V out = vrt_list(0);
    int32_t pos = 0, ms, me;
    while (pos <= m.n && rx_search(&m, pos, &ms, &me)) {
        vrt_list_push(out, sub_text(AS_STR(text), ms, me));
        m.must_adv = me == ms;
        pos = me;
    }
    return out;
}

static V b_regex_search(int argc, V *a) {
    NEED(2, "regex_search");
    V text = vrt_display(a[0]), pat = vrt_display(a[1]);
    Prog *p = get_prog(pat);
    M m;
    setup(&m, p, AS_STR(text));
    int32_t ms, me;
    if (!rx_search(&m, 0, &ms, &me)) return VNIL;
    V r = vrt_map();
    vrt_map_set(r, vrt_cstr("match"), sub_text(AS_STR(text), ms, me));
    vrt_map_set(r, vrt_cstr("start"), VI(ms));
    vrt_map_set(r, vrt_cstr("end"), VI(me));
    V groups = vrt_list(p->ngroups);
    for (int g = 1; g <= p->ngroups; g++) vrt_list_push(groups, group_text(AS_STR(text), g));
    vrt_map_set(r, vrt_cstr("groups"), groups);
    return r;
}

static V b_regex_split(int argc, V *a) {
    NEED(2, "regex_split");
    V text = vrt_display(a[0]), pat = vrt_display(a[1]);
    Prog *p = get_prog(pat);
    M m;
    setup(&m, p, AS_STR(text));
    VStr *t = AS_STR(text);
    V out = vrt_list(0);
    int32_t pos = 0, last = 0, ms, me;
    while (pos <= m.n && rx_search(&m, pos, &ms, &me)) {
        vrt_list_push(out, sub_text(t, last, ms));
        for (int g = 1; g <= p->ngroups; g++) vrt_list_push(out, group_text(t, g));
        last = me;
        m.must_adv = me == ms;
        pos = me;
    }
    vrt_list_push(out, sub_text(t, last, m.n));
    return out;
}

/* replacement templates: literal bytes and group references (Python's parse_template rules) */
typedef struct { int g; int64_t off, len; } TPiece;
typedef struct { char *b; int64_t len, cap; } Buf;
static void buf_add(Buf *b, const char *s, int64_t n) {
    if (b->len + n > b->cap) {
        b->cap = (b->len + n) * 2 + 64;
        b->b = xrealloc(b->b, (size_t)b->cap);
    }
    memcpy(b->b + b->len, s, (size_t)n);
    b->len += n;
}

static V b_replace_all(int argc, V *a) {
    NEED(3, "replace_all");
    V text = vrt_display(a[0]), pat = vrt_display(a[1]), rep = vrt_display(a[2]);
    Prog *p = get_prog(pat);
    VStr *rs = AS_STR(rep);
    const char *r = rs->data;
    int64_t rn = rs->len;
    /* parse the template into lit (bytes) + pieces */
    Buf lit = {0};
    TPiece *pcs = NULL;
    int np = 0, capp = 0;
    char err[300];
    err[0] = 0;
    int64_t litstart = 0;
#define ADDPIECE(G) do { \
        if (np + 2 > capp) { capp = capp ? capp * 2 : 8; pcs = xrealloc(pcs, sizeof(TPiece) * (size_t)capp); } \
        if (lit.len > litstart) { pcs[np].g = -1; pcs[np].off = litstart; pcs[np].len = lit.len - litstart; np++; } \
        litstart = lit.len; \
        if ((G) >= 0) { pcs[np].g = (G); pcs[np].off = pcs[np].len = 0; np++; } \
    } while (0)
    for (int64_t i = 0; i < rn && !err[0];) {
        char c = r[i++];
        if (c != '\\') { buf_add(&lit, &c, 1); continue; }
        if (i >= rn) { snprintf(err, sizeof err, "bad escape (end of pattern) at position %lld", (long long)(i - 1)); break; }
        int64_t start = i - 1;
        c = r[i++];
        if (c == 'g') {
            if (i >= rn || r[i] != '<') { snprintf(err, sizeof err, "missing < at position %lld", (long long)i); break; }
            i++;
            int64_t ns = i;
            while (i < rn && r[i] != '>') i++;
            if (i >= rn) {
                if (ns == rn) snprintf(err, sizeof err, "missing group name at position %lld", (long long)ns);
                else snprintf(err, sizeof err, "missing >, unterminated name at position %lld", (long long)ns);
                break;
            }
            int64_t ne = i++;
            if (ne == ns) { snprintf(err, sizeof err, "missing group name at position %lld", (long long)ns); break; }
            char name[256];
            int64_t nl = ne - ns < 255 ? ne - ns : 255;
            memcpy(name, r + ns, (size_t)nl);
            name[nl] = 0;
            int isnum = 1;
            long long num = 0;
            for (int64_t j = ns; j < ne; j++) {
                if (!isdig((unsigned char)r[j])) { isnum = 0; break; }
                if (num < 1000000000LL) num = num * 10 + (r[j] - '0');
            }
            int g = -1;
            if (isnum) {
                if (num > p->ngroups) { snprintf(err, sizeof err, "invalid group reference %lld at position %lld", num, (long long)(ns)); break; }
                g = (int)num;
            } else {
                for (int k = 1; k <= p->ngroups; k++) if (p->names[k] && strcmp(p->names[k], name) == 0) { g = k; break; }
                if (g < 0) {
                    int ident = !isdig((unsigned char)name[0]);
                    for (int64_t j = 0; j < nl; j++) {
                        unsigned char ch = (unsigned char)name[j];
                        if (!(ch >= 128 || isasciiletter(ch) || isdig(ch) || ch == '_')) ident = 0;
                    }
                    if (!ident) snprintf(err, sizeof err, "bad character in group name '%s' at position %lld", name, (long long)ns);
                    else snprintf(err, sizeof err, "unknown group name '%s'", name);
                    break;
                }
            }
            ADDPIECE(g);
        } else if (c == '0') {
            int v = 0;
            for (int k = 0; k < 2 && i < rn && isoct((unsigned char)r[i]); k++) v = v * 8 + (r[i++] - '0');
            char o[4];
            buf_add(&lit, o, enc_utf8(o, v));
        } else if (isdig((unsigned char)c)) {
            int g = c - '0';
            if (i < rn && isdig((unsigned char)r[i])) {
                char d = r[i++];
                if (isoct((unsigned char)c) && isoct((unsigned char)d) && i < rn && isoct((unsigned char)r[i])) {
                    int v = (c - '0') * 64 + (d - '0') * 8 + (r[i++] - '0');
                    if (v > 0377) { snprintf(err, sizeof err, "octal escape value \\%c%c%c outside of range 0-0o377 at position %lld", c, d, r[i - 1], (long long)start); break; }
                    char o[4];
                    buf_add(&lit, o, enc_utf8(o, v));
                    continue;
                }
                g = g * 10 + (d - '0');
            }
            if (g > p->ngroups) { snprintf(err, sizeof err, "invalid group reference %d at position %lld", g, (long long)(start + 1)); break; }
            ADDPIECE(g);
        } else {
            int32_t e = c == 'b' ? 8 : simple_escape((unsigned char)c);
            if (e >= 0) { char ch = (char)e; buf_add(&lit, &ch, 1); }
            else if (isasciiletter((unsigned char)c)) { snprintf(err, sizeof err, "bad escape \\%c at position %lld", c, (long long)start); break; }
            else { buf_add(&lit, "\\", 1); buf_add(&lit, &c, 1); }
        }
    }
    if (err[0]) { free(lit.b); free(pcs); vrt_fail("that pattern is not valid: %s", err); }
    ADDPIECE(-1);
#undef ADDPIECE
    M m;
    VStr *t = AS_STR(text);
    setup(&m, p, t);
    Buf out = {0};
    int32_t pos = 0, last = 0, ms, me;
    while (pos <= m.n && rx_search(&m, pos, &ms, &me)) {
        buf_add(&out, t->data + offs[last], offs[ms] - offs[last]);
        for (int k = 0; k < np; k++) {
            if (pcs[k].g < 0) buf_add(&out, lit.b + pcs[k].off, pcs[k].len);
            else {
                int g = pcs[k].g;
                int32_t ga = g == 0 ? ms : regs[2 * g], gb = g == 0 ? me : regs[2 * g + 1];
                if (ga >= 0 && gb >= 0) buf_add(&out, t->data + offs[ga], offs[gb] - offs[ga]);
            }
        }
        last = me;
        m.must_adv = me == ms;
        pos = me;
    }
    buf_add(&out, t->data + offs[last], offs[m.n] - offs[last]);
    V res = vrt_str(out.b ? out.b : "", out.len);
    free(out.b); free(lit.b); free(pcs);
    return res;
}

static V b_regex_escape(int argc, V *a) {
    NEED(1, "regex_escape");
    VStr *t = AS_STR(vrt_display(a[0]));
    Buf out = {0};
    static const char special[] = "()[]{}?*+-|^$\\.&~# \t\n\r\v\f";
    for (int64_t i = 0; i < t->len; i++) {
        char c = t->data[i];
        if (c && memchr(special, c, sizeof special - 1)) buf_add(&out, "\\", 1);
        buf_add(&out, &c, 1);
    }
    V res = vrt_str(out.b ? out.b : "", out.len);
    free(out.b);
    return res;
}

typedef VEntry Entry;
static const Entry regex_table[] = {
    {"matches", b_matches}, {"find_all", b_find_all}, {"replace_all", b_replace_all},
    {"regex_search", b_regex_search}, {"regex_split", b_regex_split}, {"regex_escape", b_regex_escape},
    {NULL, NULL}
};
__attribute__((constructor)) static void vrt_regex_register(void) { vrt_register_builtins(regex_table); }
