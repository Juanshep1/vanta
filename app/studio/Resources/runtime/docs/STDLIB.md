# Vanta Standard Library Reference

Vanta's builtin functions are always available: you do not import anything to use them. You call a builtin like any other function, with its name followed by values in parentheses, for example `length(names)` or `say uppercase("hi")`. Builtins are also values, so you can pass one to another function, as in `map(uppercase, words)`.

How to read this reference:

- Each heading shows a builtin and the values it takes. Optional values are shown in [brackets]: `round(x, [digits])` can be called as `round(x)` or `round(x, digits)`. A trailing `...` means you can pass any number of values.
- The example under each entry is real Vanta code. The `#` comment shows what it prints.
- Builtins that take text (for example `uppercase` or `read_file`) turn any other value into text first, the same way `text()` does.
- When a builtin is given the wrong kind of value, it stops the program with an error in plain English (for example `sqrt` says "can't take the square root of a negative number"). You can catch these errors with `attempt` / `rescue`.
- "Native" means the function also works in programs compiled with `vanta build`. Every function works in the interpreter (`vanta file.va`). Entries marked *Interpreter only.* are not available in native builds yet.
- If you define your own function or variable with the same name as a builtin, your name wins (it shadows the builtin) for the rest of that scope.
- `expect` lines in tests call a hidden helper named `__vanta_expect`. It is part of the `expect` statement, not something you call yourself, so it is not listed here.

Several examples use these small helper functions:

```
to square(n)
    give back n * n
end

to is_even(n)
    give back n % 2 is 0
end

to add(a, b)
    give back a + b
end
```

## Contents

- [Output & conversion](#output--conversion)
- [Text](#text)
- [Numbers & math](#numbers--math)
- [Lists](#lists)
- [Maps](#maps)
- [Sets & generators](#sets--generators)
- [Higher-order functions](#higher-order-functions)
- [Errors & testing](#errors--testing)
- [Files & folders](#files--folders)
- [Paths](#paths)
- [System & processes](#system--processes)
- [Time & dates](#time--dates)
- [JSON & encoding](#json--encoding)
- [Regular expressions](#regular-expressions)
- [Bytes & bits](#bytes--bits)
- [The web](#the-web)
- [Memory toolkit](#memory-toolkit)
- [Keyboard & mouse](#keyboard--mouse)
- [Concurrency](#concurrency)
- [Handles: files, sockets, processes](#handles-files-sockets-processes)
- [Networking](#networking)
- [The web server](#the-web-server)
- [Processes & environment](#processes--environment)
- [More files & folders](#more-files--folders)
- [Data](#data)
- [Standard modules](#standard-modules)

## Output & conversion

### `length(value)`
Gives back how many characters are in a text, items in a list, keys in a map, values in a set, or bytes in a bytes value. Any other value is an error.
`say length("hello")   # 5`

### `text(value)`
Gives back any value as text, exactly as `say` would print it (`yes`/`no` for yes-no values, `nothing` for nothing, `[1, 2]` for lists).
`say text(42) + "!"   # 42!`

### `number(value)`
Turns text such as `"12"` or `"3.5"` into a number; a number is given back unchanged. Text that is not a number, or a yes-no value, is an error (for example `"abc" is not a number`).
`say number("3.5") + 1   # 4.5`

### `typeof(value)`
The older, short type check: gives back `"bool"`, `"number"`, `"text"`, `"list"`, `"map"` or `"bytes"` (or the kind of a runtime handle, as `type_of` does), and `"nothing"` for everything else, including functions, sets and objects. Prefer `type_of` in new code.
`say typeof(yes)   # bool`

### `type_of(value)`
Gives back the name of a value's type: `"nothing"`, `"yes-no"`, `"number"`, `"text"`, `"list"`, `"map"`, `"set"`, `"bytes"`, `"function"`, `"type"`, the name of your own type for an object (such as `"Dog"`), or the kind of a runtime handle (such as `"task"`, `"socket"` or `"file"`).
`say type_of(yes)   # yes-no`

### `is_number(value)`
Gives back `yes` if the value is a number (whole or decimal), otherwise `no`. Yes-no values are not numbers.
`say is_number(5)   # yes`

### `is_text(value)`
Gives back `yes` if the value is text, otherwise `no`.
`say is_text("5")   # yes`

### `is_list(value)`
Gives back `yes` if the value is a list, otherwise `no`.
`say is_list([])   # yes`

### `is_map(value)`
Gives back `yes` if the value is a map, otherwise `no`.
`say is_map({"a": 1})   # yes`

### `is_set(value)`
Gives back `yes` if the value is a set (made with `set`), otherwise `no`.
`say is_set(set([1, 2]))   # yes`

### `is_bytes(value)`
Gives back `yes` if the value is a bytes value (made with `bytes` or `read_binary`), otherwise `no`. A plain list of numbers is not bytes.
`say is_bytes(bytes(4))   # yes`

### `is_function(value)`
Gives back `yes` if the value can be called: a function you wrote, a builtin, or a method of an object.
`say is_function(square)   # yes`

### `is_nothing(value)`
Gives back `yes` if the value is `nothing`, otherwise `no`.
`say is_nothing(nothing)   # yes`

### `is_a(value, type)`
Gives back `yes` if the value is an object of the given type or of a type that comes `from` it. The second value must be a type, otherwise it is an error.
`say is_a(new Circle(2), Shape)   # yes (Circle is a type that comes from Shape)`

### `list([value])`
Turns a text, map, set, bytes value or generator into a list: the characters of a text, the keys of a map, the values of a set, the numbers of a bytes value, or every value a generator makes. With no value it gives back an empty list.
`say list("abc")   # ["a", "b", "c"]`

### `format(value, spec)`
Gives back the value as text shaped by a format spec, the same spec you can write after a colon inside `{...}` in text: `.2` for two decimals, `8` for a width of 8, `05` to pad with zeros, `,` for thousands separators, `<` `>` `^` to align left, right or centre (optionally after a fill character), and a final `f`, `e`, `%`, `x`, `X`, `b`, `o` or `s` for fixed, scientific, percent, hex, binary, octal or text. A spec it does not understand is an error.
`say format(3.14159, ".2")   # 3.14`

## Text

Positions in text start at 0. Functions that search give back -1 when nothing is found.

### `uppercase(text)`
Gives back the text in capital letters.
`say uppercase("hi")   # HI`

### `lowercase(text)`
Gives back the text in small letters.
`say lowercase("HeLLo")   # hello`

### `capitalize(text)`
Gives back the text with its first character in capitals and the rest left as it was.
`say capitalize("hello world")   # Hello world`

### `title_case(text)`
Gives back the text with the first letter of every word in capitals and the other letters small.
`say title_case("hello big world")   # Hello Big World`

### `trim(text)`
Gives back the text without the spaces, tabs and line breaks at its start and end.
`say "[" + trim("  hi  ") + "]"   # [hi]`

### `replace(text, old, new)`
Gives back the text with every copy of `old` replaced by `new`. (For patterns, use `replace_all`.)
`say replace("a-b-c", "-", "+")   # a+b+c`

### `starts_with(text, start)`
Gives back `yes` if the text begins with `start`, otherwise `no`.
`say starts_with("vanta", "va")   # yes`

### `ends_with(text, ending)`
Gives back `yes` if the text ends with `ending`, otherwise `no`.
`say ends_with("file.va", ".va")   # yes`

### `find(text, part)`
Gives back the position where `part` first appears in the text, or -1 if it does not appear.
`say find("hello", "l")   # 2`

### `index_of(text_or_list, item)`
For text, gives back the position where `item` first appears (like `find`); for a list, gives back the position of the first item equal to `item`. Gives back -1 when it is not there; any other first value is an error.
`say index_of([10, 20, 30], 20)   # 1`

### `last_index_of(text_or_list, item)`
Like `index_of`, but gives back the position of the last match instead of the first, or -1 when there is none.
`say last_index_of("banana", "a")   # 5`

### `split(text, separator)`
Cuts the text at every copy of the separator and gives back the pieces as a list of text.
`say split("a,b,c", ",")   # ["a", "b", "c"]`

### `lines(text)`
Cuts the text at every line break and gives back the lines as a list.
`say lines("one\ntwo")   # ["one", "two"]`

### `pad_left(text, width, [fill])`
Gives back the text with copies of `fill` (a space if left out; only its first character is used) added on the left until it is `width` characters long. Text that is already long enough is given back unchanged.
`say pad_left("7", 3, "0")   # 007`

### `pad_right(text, width, [fill])`
Like `pad_left`, but adds the fill characters on the right.
`say pad_right("ab", 5, ".") + "|"   # ab...|`

### `repeat_text(text, count)`
Gives back the text repeated `count` times. A negative count is an error.
`say repeat_text("ab", 3)   # ababab`

### `chr(code)`
Gives back the one-character text for a Unicode code number (0 to 1114111).
`say chr(65)   # A`

### `code(text)`
Gives back the Unicode code number of the first character of the text. Empty text is an error.
`say code("A")   # 65`

## Numbers & math

Angles are in radians. Functions that need a number stop with an error when given anything else.

### `abs(x)`
Gives back the number without its minus sign.
`say abs(-4)   # 4`

### `round(x, [digits])`
Rounds to the nearest whole number, or to `digits` decimal places. Exact halves round to the even neighbour, so `round(2.5)` is 2 and `round(3.5)` is 4. A negative `digits` rounds to tens, hundreds and so on.
`say round(3.14159, 2)   # 3.14`

### `floor(x)`
Gives back the largest whole number that is not above `x`.
`say floor(3.7)   # 3`

### `ceil(x)`
Gives back the smallest whole number that is not below `x`.
`say ceil(3.2)   # 4`

### `sqrt(x)`
Gives back the square root. A negative number is an error.
`say sqrt(16)   # 4`

### `power(base, exponent)`
Gives back `base` raised to `exponent`.
`say power(2, 10)   # 1024`

### `min(values...)`
Gives back the smallest value. Pass either one list or several values; they must be all numbers or all text (text is compared alphabetically). No values at all is an error.
`say min(3, 1, 2)   # 1`

### `max(values...)`
Gives back the largest value, with the same rules as `min`.
`say max([4, 9, 2])   # 9`

### `sum(list)`
Gives back the total of a list of numbers (0 for an empty list).
`say sum([1, 2, 3])   # 6`

### `product(list)`
Gives back all the numbers in a list multiplied together (1 for an empty list).
`say product([2, 3, 4])   # 24`

### `clamp(x, low, high)`
Gives back `x` limited to the range from `low` to `high`. It is an error if `low` is above `high`.
`say clamp(15, 0, 10)   # 10`

### `sign(x)`
Gives back -1 for a negative number, 0 for zero, and 1 for a positive number.
`say sign(-3)   # -1`

### `sin(angle)`
Gives back the sine of an angle in radians.
`say sin(0)   # 0`

### `cos(angle)`
Gives back the cosine of an angle in radians.
`say cos(0)   # 1`

### `tan(angle)`
Gives back the tangent of an angle in radians.
`say tan(0)   # 0`

### `asin(x)`
Gives back the angle (in radians) whose sine is `x`. `x` must be between -1 and 1.
`say asin(1)   # 1.5707963267948966`

### `acos(x)`
Gives back the angle (in radians) whose cosine is `x`. `x` must be between -1 and 1.
`say acos(1)   # 0`

### `atan(x)`
Gives back the angle (in radians) whose tangent is `x`.
`say atan(1)   # 0.7853981633974483`

### `atan2(y, x)`
Gives back the angle (in radians) from the x-axis to the point (`x`, `y`), taking the signs of both into account. Note that `y` comes first.
`say atan2(1, 1)   # 0.7853981633974483`

### `log(x, [base])`
Gives back the natural logarithm of `x`, or the logarithm in the given base. `x` and `base` must be above zero.
`say log(100, 10)   # 2`

### `exp(x)`
Gives back e (2.718...) raised to `x`.
`say exp(1)   # 2.718281828459045`

### `random(low, high)`
Gives back a random whole number from `low` to `high`, including both ends. Both must be whole numbers, low first.
`say random(1, 6)   # 4`

### `random_float()`
Gives back a random decimal number from 0 up to (but not including) 1.
`say random_float()   # 0.6394267984578837`

### `format_number(x, [digits])`
Gives back the number as text with commas between thousands and exactly `digits` decimal places (0 if left out).
`say format_number(1234567.891, 2)   # 1,234,567.89`

## Lists

Positions in lists start at 0, and -1 means the last item. Functions marked "changes the list" modify the list you pass in; the others give back a new list and leave the original alone.

### `first(list_or_text)`
Gives back the first item of a list (or first character of a text). An empty list or text is an error.
`say first([5, 6, 7])   # 5`

### `last(list_or_text)`
Gives back the last item of a list (or last character of a text). An empty list or text is an error.
`say last("abc")   # c`

### `range([start], end)`
Gives back a list of whole numbers counting up from `start` (0 if left out) to just before `end`.
`say range(2, 5)   # [2, 3, 4]`

### `contains(collection, item)`
Gives back `yes` if a list has the item, a text has it as a part, a map has it as a key, or a set has it as a value.
`say contains("hello", "ell")   # yes`

### `join(list, separator)`
Gives back one text made of every item of the list (turned into text) with the separator between them.
`say join(["a", "b"], ", ")   # a, b`

### `sort(list, [order])`
Gives back a sorted copy of a list of all numbers or all text. Pass `"desc"` (or `"descending"`/`"reverse"`) to sort from largest to smallest; `"asc"` is the default. A mixed list is an error.
`say sort([3, 1, 2], "desc")   # [3, 2, 1]`

### `reverse(list_or_text)`
Gives back a copy of the list, or the text, in the opposite order.
`say reverse("abc")   # cba`

### `slice(list_or_text, start, end)`
Gives back the items (or characters) from position `start` up to, but not including, position `end`. Negative positions count from the end.
`say slice([1, 2, 3, 4], 1, 3)   # [2, 3]`

### `push(list, item)`
Adds the item to the end of the list (changes the list) and gives back nothing.
`push(scores, 90)   # scores is now [70, 80, 90]`

### `pop(list)`
Removes the last item of the list (changes the list) and gives it back. An empty list is an error.
`say pop([1, 2, 3])   # 3`

### `remove_at(list, position)`
Removes the item at the position (changes the list) and gives it back. A position outside the list is an error.
`say remove_at([10, 20, 30], 0)   # 10`

### `insert_at(list, position, item)`
Gives back a new list with the item inserted before the given position; the original list is not changed.
`say insert_at([1, 3], 1, 2)   # [1, 2, 3]`

### `unique(list)`
Gives back the list with repeated items removed, keeping the first copy of each in order.
`say unique([1, 2, 2, 3, 1])   # [1, 2, 3]`

### `zip(list_a, list_b)`
Pairs up items from two lists by position and gives back a list of two-item lists, as long as the shorter list.
`say zip([1, 2], ["a", "b"])   # [[1, "a"], [2, "b"]]`

### `flatten(list)`
Gives back the list with any inner lists opened up one level.
`say flatten([[1, 2], [3], 4])   # [1, 2, 3, 4]`

### `chunk(list, size)`
Splits the list into smaller lists of `size` items each (the last may be shorter). The size must be at least 1.
`say chunk([1, 2, 3, 4, 5], 2)   # [[1, 2], [3, 4], [5]]`

### `shuffle(list)`
Gives back a copy of the list in a random order.
`say shuffle([1, 2, 3])   # [2, 3, 1]`

### `pick(list)`
Gives back one item of the list chosen at random. An empty list is an error.
`say pick(["rock", "paper", "scissors"])   # paper`

## Maps

### `keys(map)`
Gives back a list of the map's keys, in the order they were added.
`say keys({"a": 1, "b": 2})   # ["a", "b"]`

### `values(map)`
Gives back a list of the map's values, in the order they were added.
`say values({"a": 1, "b": 2})   # [1, 2]`

### `entries(map)`
Gives back a list of `[key, value]` pairs.
`say entries({"a": 1, "b": 2})   # [["a", 1], ["b", 2]]`

### `get(map, key, [fallback])`
Gives back the value stored under the key, or `fallback` (nothing if left out) when the key is missing. Unlike `map[key]`, a missing key is not an error.
`say get({"a": 1}, "b", 0)   # 0`

### `has_key(map, key)`
Gives back `yes` if the map has the key, otherwise `no`.
`say has_key({"a": 1}, "a")   # yes`

### `remove_key(map, key)`
Gives back a copy of the map without the key; the original map is not changed. A missing key is not an error.
`say remove_key({"a": 1, "b": 2}, "a")   # {"b": 2}`

### `merge(map1, map2, ...)`
Gives back a new map with the keys of all the maps; when a key appears more than once, the later map wins. At least two maps are needed.
`say merge({"a": 1}, {"b": 2}, {"a": 3})   # {"a": 3, "b": 2}`

## Sets & generators

A set holds each value at most once, in the order the values were first added. Only simple values (numbers, text, yes/no) can go in a set.

### `set([values])`
Makes a set from a list (or the characters of a text, the keys of a map, and so on), dropping repeats. With no value it makes an empty set. A list or map inside the values is an error.
`say set([1, 2, 2, 3])   # set([1, 2, 3])`

### `union(set_a, set_b)`
Gives back a new set with every value that is in either set. Both values must be sets.
`say union(set([1, 2]), set([2, 3]))   # set([1, 2, 3])`

### `intersection(set_a, set_b)`
Gives back a new set with only the values that are in both sets.
`say intersection(set([1, 2, 3]), set([2, 3, 4]))   # set([2, 3])`

### `difference(set_a, set_b)`
Gives back a new set with the values of `set_a` that are not in `set_b`.
`say difference(set([1, 2, 3]), set([2]))   # set([1, 3])`

### `is_subset(set_a, set_b)`
Gives back `yes` if every value of `set_a` is also in `set_b`.
`say is_subset(set([1, 2]), set([1, 2, 3]))   # yes`

### `next(generator, [fallback])`
Gives back the next value from a generator (what calling a function that uses `yield` gives back). When the generator has no more values, it gives back `fallback` if you passed one, and is an error otherwise.
`say next(countdown, "done")   # done (when countdown has finished)`

## Higher-order functions

These take a function as their first value and a list as their second. The function can be one you wrote or a builtin.

### `map(function, list)`
Calls the function on every item and gives back a list of the results.
`say map(square, [1, 2, 3])   # [1, 4, 9]`

### `keep(function, list)`
Gives back a list of only the items for which the function gives back a true value.
`say keep(is_even, [1, 2, 3, 4])   # [2, 4]`

### `reduce(function, list, start)`
Combines the items one by one: the function is called with the running result (beginning with `start`) and the next item, and the final result is given back.
`say reduce(add, [1, 2, 3], 0)   # 6`

### `each(function, list)`
Calls the function on every item, for its effect, and gives back nothing.
`each(say_hello, ["Ana", "Ben"])   # calls say_hello("Ana"), then say_hello("Ben")`

### `count_where(function, list)`
Gives back how many items the function says yes to.
`say count_where(is_even, [1, 2, 3, 4])   # 2`

### `find_where(function, list)`
Gives back the first item the function says yes to, or nothing if there is none.
`say find_where(is_even, [1, 3, 4, 6])   # 4`

### `any_where(function, list)`
Gives back `yes` if the function says yes to at least one item.
`say any_where(is_even, [1, 3, 4])   # yes`

### `all_where(function, list)`
Gives back `yes` if the function says yes to every item (and for an empty list).
`say all_where(is_even, [2, 4, 5])   # no`

### `sort_by(function, list)`
Gives back a copy of the list sorted by the value the function gives back for each item. Those values must be all numbers or all text. Items with equal values keep their order.
`say sort_by(length, ["ccc", "a", "bb"])   # ["a", "bb", "ccc"]`

## Errors & testing

### `fail(message)`
Stops the program with an error carrying the message. Inside `attempt`, the error goes to `rescue` instead, with the message as its value.
`fail("out of fuel")   # error: out of fuel`

### `assert(condition, [message])`
Does nothing if the condition is true. Otherwise it stops with an error carrying the message, or "assertion failed" if there is no message.
`assert(1 is 2, "math is broken")   # error: math is broken`

## Files & folders

Paths are text. A relative path is taken from the folder the program was started in. Reading a file that is missing, or writing where you are not allowed to, is an error that starts with "could not ...".

### `read_file(path)`
Gives back the whole contents of a text file.
`say read_file("notes.txt")   # hello world`

### `write_file(path, text)`
Writes the text to the file, replacing whatever was there (the file is created if needed). Gives back nothing.
`write_file("notes.txt", "hello")   # notes.txt now holds "hello"`

### `append_file(path, text)`
Adds the text to the end of the file (creating the file if needed). Gives back nothing.
`append_file("notes.txt", " world")   # notes.txt now holds "hello world"`

### `read_bytes(path)`
Gives back the contents of any file (including images and other binary files) as a list of numbers from 0 to 255.
`say read_bytes("hi.bin")   # [72, 105]`

### `write_bytes(path, numbers)`
Writes a list of numbers (each kept to 0-255) to the file as raw bytes, replacing what was there. It must be given a list; use `write_binary` for a bytes value.
`write_bytes("hi.bin", [72, 105])   # hi.bin now holds "Hi"`

### `read_binary(path)`
Gives back the contents of any file as a compact bytes value; much faster than `read_bytes` for big files such as game data.
`say read_binary("hi.bin")   # bytes[48 69]`

### `write_binary(path, data)`
Writes a bytes value (or a list of numbers from 0 to 255) to the file, replacing what was there. Gives back nothing.
`write_binary("copy.bin", read_binary("hi.bin"))   # copy.bin now holds "Hi"`

### `make_dir(path)`
Creates the folder, along with any missing parent folders. A folder that already exists is not an error.
`make_dir("output/images")   # creates output and output/images`

### `remove_path(path)`
Deletes a file, or a folder together with everything inside it. A path that does not exist is not an error. Use with care: nothing goes to the trash.
`remove_path("output")   # output and everything in it are gone`

### `list_dir(path)`
Gives back the names of the files and folders inside a folder, sorted alphabetically.
`say list_dir("project")   # ["main.va", "notes.txt"]`

### `path_exists(path)`
Gives back `yes` if a file or folder exists at the path.
`say path_exists("notes.txt")   # yes`

### `is_file(path)`
Gives back `yes` if the path is an existing file (not a folder).
`say is_file("notes.txt")   # yes`

### `is_dir(path)`
Gives back `yes` if the path is an existing folder.
`say is_dir("output")   # yes`

### `file_size(path)`
Gives back the size of the file in bytes.
`say file_size("notes.txt")   # 11`

### `file_mtime(path)`
Gives back when the file was last changed, as whole seconds since 1 January 1970 (the same kind of number as `now()`).
`say format_date(file_mtime("notes.txt"))   # 2026-10-21 09:15:02`

### `copy_path(source, destination)`
Copies a file, or a whole folder with its contents, to the destination. Missing parent folders of the destination are created. Gives back nothing.
`copy_path("notes.txt", "backup/notes.txt")   # backup/notes.txt is a copy`

### `move_path(source, destination)`
Moves (or renames) a file or folder. Missing parent folders of the destination are created. Gives back nothing.
`move_path("draft.txt", "final/report.txt")   # draft.txt is now final/report.txt`

## Paths

These work on path text only; they do not look at the disk.

### `path_join(parts...)`
Joins the parts into one path with the right separator for the system. With no parts it gives back empty text.
`say path_join("docs", "guide", "intro.md")   # docs/guide/intro.md`

### `dirname(path)`
Gives back the folder part of a path (everything before the last separator).
`say dirname("/home/ana/notes.txt")   # /home/ana`

### `basename(path)`
Gives back the last part of a path, usually the file name.
`say basename("/home/ana/notes.txt")   # notes.txt`

### `extname(path)`
Gives back the file extension, including the dot, or empty text if there is none.
`say extname("photo.final.png")   # .png`

### `home_dir()`
Gives back the path of the current user's home folder.
`say home_dir()   # /Users/ana`

## System & processes

### `run(command, [folder])`
Runs a shell command (optionally inside `folder`), waits for it to finish, and gives back everything it printed (normal output followed by error output) as text, without the final line break.
`say run("echo hi")   # hi`

### `shell(command, [folder], [variables])`
Like `run`, but gives back a map with `output` (the printed text) and `code` (the exit code, 0 for success). The optional third value is a map of extra environment variables for the command.
`say shell("echo hi; exit 3")   # {"output": "hi", "code": 3}`

### `arguments()`
Gives back the list of words typed after the program's file name on the command line.
`say arguments()   # ["a", "b"] (for: vanta app.va a b)`

### `env(name, [fallback])`
Gives back the value of an environment variable; if it is not set, gives back `fallback`, or empty text when there is no fallback.
`say env("HOME")   # /Users/ana`

### `os_name()`
Gives back `"mac"`, `"linux"` or `"windows"` for the system the program is running on.
`say os_name()   # mac`

### `interpreter()`
Gives back the full path of the Vanta interpreter file that is running the program.
`say interpreter()   # /Users/ana/vanta/vanta.py`
*Interpreter only.*

### `run_vanta(code, [name])`
Runs Vanta source code given as text, in a fresh scope inside the same program, and captures what it prints. Gives back a map with `ok` (`yes` or `no`), `output` (the printed text) and `error` (the error message, or empty text). Errors in the code never stop the caller. The optional name is accepted but currently not used.
`say run_vanta("say 1 + 2")["output"]   # 3`
*Interpreter only.*

### `run_file(path)`
Reads a `.va` file and runs it the same way as `run_vanta`, giving back the same `ok` / `output` / `error` map. A missing file is an error.
`say run_file("hello.va")["ok"]   # yes`
*Interpreter only.*

### `run_detached(path)`
Starts a `.va` file running as a separate program in the background (useful for servers and other programs that never finish) and gives back its process id straight away.
`let pid be run_detached("server.va")   # server.va keeps running on its own`
*Interpreter only.*

### `open_url(address)`
Opens a web address (or a file) in the default browser and gives back nothing. On an Android phone running Termux it uses `termux-open-url`; if nothing can open it, the address is printed instead.
`open_url("https://example.com")   # the page opens in the browser`
*Interpreter only.*

## Time & dates

Timestamps are whole seconds since 1 January 1970 (UTC). Dates and clock times use the computer's local time zone. Date patterns use `%` codes: `%Y` year, `%m` month number, `%d` day, `%H` hour (24-hour), `%M` minutes, `%S` seconds, `%B` month name, `%A` weekday name.

### `now()`
Gives back the current time as a timestamp in whole seconds.
`say now()   # 1792604949`

### `now_ms()`
Gives back the current time in milliseconds since 1970; subtract two readings to time something.
`say now_ms() - start   # 125`

### `today()`
Gives back today's date as text in the form `YYYY-MM-DD`.
`say today()   # 2026-10-21`

### `clock()`
Gives back the current time of day as text in the form `HH:MM:SS`.
`say clock()   # 23:29:09`

### `sleep(seconds)`
Pauses the program for the given number of seconds (decimals allowed, such as 0.5) and gives back nothing.
`sleep(0.5)   # waits half a second`

### `format_date(timestamp, [pattern], [zone])`
Gives back a timestamp as text using the pattern; without a pattern it uses `"%Y-%m-%d %H:%M:%S"`. The optional zone is a time-zone name such as `"UTC"` or `"Europe/Paris"`; without it the local time zone is used.
`say format_date(parse_date("2024-03-15"), "%d %B %Y")   # 15 March 2024`

### `parse_date(text, [pattern], [zone])`
Reads a date written as text and gives back its timestamp; without a pattern it expects `"%Y-%m-%d"`. The optional zone (such as `"UTC"`) says which time zone the text is in; without it the local time zone is used. Text that does not fit the pattern is an error.
`say format_date(parse_date("2024-03-15"))   # 2024-03-15 00:00:00`

## JSON & encoding

### `to_json(value, [indent])`
Gives back the value written as JSON text: `yes`/`no` become `true`/`false` and `nothing` becomes `null`. With `indent`, the JSON is spread over several lines, indented by that many spaces. Values JSON cannot hold (such as functions or bytes) are an error.
`say to_json({"ok": yes, "tags": [1, 2]})   # {"ok": true, "tags": [1, 2]}`

### `from_json(text)`
Reads JSON text and gives back the matching Vanta value: objects become maps, arrays become lists, `true`/`false` become `yes`/`no`, and `null` becomes `nothing`. Invalid JSON is an error.
`say from_json("[1, 2.5, true, null]")   # [1, 2.5, yes, nothing]`

### `base64_encode(text)`
Gives back the text (as UTF-8) encoded in Base64.
`say base64_encode("hello")   # aGVsbG8=`

### `base64_decode(text)`
Decodes Base64 text back into text. Invalid Base64 is an error.
`say base64_decode("aGVsbG8=")   # hello`

### `base64_to_bytes(text)`
Decodes Base64 text into a list of numbers from 0 to 255; use this for binary data such as images.
`say base64_to_bytes("SGk=")   # [72, 105]`

### `bytes_to_base64(numbers)`
Encodes a list of numbers from 0 to 255 as Base64 text (for example to build a `data:` address).
`say bytes_to_base64([72, 105])   # SGk=`

### `hex_encode(text)`
Gives back the text's UTF-8 bytes written as hexadecimal digits.
`say hex_encode("Hi")   # 4869`

### `hex_decode(text)`
Turns hexadecimal digits back into text. Text that is not valid hex is an error.
`say hex_decode("4869")   # Hi`

### `sha256(data)`
Gives back the SHA-256 hash of a text (as UTF-8) or a bytes value, as 64 hexadecimal digits.
`say sha256("abc")   # ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad`

### `md5(data)`
Gives back the MD5 hash of a text (as UTF-8) or a bytes value, as 32 hexadecimal digits (fine for checksums, not for security).
`say md5("abc")   # 900150983cd24fb0d6963f7d28e17f72`

### `url_encode(text)`
Gives back the text made safe to put inside a web address: everything except letters, digits and `_ . - ~` is written as `%` codes.
`say url_encode("a b&c")   # a%20b%26c`

### `url_decode(text)`
Turns `%` codes in web-address text back into normal characters.
`say url_decode("a%20b%26c")   # a b&c`

### `html_escape(text)`
Gives back the text made safe to put inside HTML: `&`, `<`, `>`, `"` and `'` are replaced by HTML entities.
`say html_escape("<b>Tom & Jerry</b>")   # &lt;b&gt;Tom &amp; Jerry&lt;/b&gt;`

## Regular expressions

Patterns use the common regular-expression syntax (`[0-9]+`, `^`, `$`, `(...)` groups and so on). A backslash must be doubled inside Vanta text, so write `"\\d+"` for the pattern `\d+`. An invalid pattern is an error.

### `matches(text, pattern)`
Gives back `yes` if the pattern is found anywhere in the text.
`say matches("hello123", "[0-9]+")   # yes`

### `find_all(text, pattern)`
Gives back a list of every part of the text that matches the pattern.
`say find_all("a1 b22 c333", "[0-9]+")   # ["1", "22", "333"]`

### `replace_all(text, pattern, replacement)`
Gives back the text with every match of the pattern replaced. In the replacement, `\\1`, `\\2` and so on stand for the pattern's groups.
`say replace_all("2024-03-15", "(\\d+)-(\\d+)-(\\d+)", "\\3/\\2/\\1")   # 15/03/2024`

## Bytes & bits

A bytes value is a compact, changeable run of numbers from 0 to 255, printed like `bytes[01 02 ff]`. The number readers and writers below use little-endian order (lowest byte first) and accept either a bytes value or a list of numbers. Reading or writing past the end is an error.

### `bytes(size_or_values)`
Makes a bytes value: `bytes(n)` gives n zero bytes, `bytes(list)` copies a list of numbers from 0 to 255, and `bytes(text)` gives the text's UTF-8 bytes.
`say bytes([1, 2, 255])   # bytes[01 02 ff]`

### `u8(data, position)`
Reads one byte at the position as a number from 0 to 255.
`say u8(bytes([200, 1]), 0)   # 200`

### `s8(data, position)`
Reads one byte at the position as a signed number from -128 to 127.
`say s8(bytes([200]), 0)   # -56`

### `u16(data, position)`
Reads two bytes starting at the position as a number from 0 to 65535.
`say u16(bytes([1, 2]), 0)   # 513`

### `s16(data, position)`
Reads two bytes starting at the position as a signed number from -32768 to 32767.
`say s16(bytes([255, 255]), 0)   # -1`

### `u32(data, position)`
Reads four bytes starting at the position as a number from 0 to 4294967295.
`say u32(bytes([1, 0, 0, 0]), 0)   # 1`

### `s32(data, position)`
Reads four bytes starting at the position as a signed number.
`say s32(bytes([255, 255, 255, 255]), 0)   # -1`

### `put_u8(data, position, value)`
Writes one byte at the position (changes the data) and gives back nothing. Values that do not fit keep only their lowest 8 bits, so 300 is stored as 44.
`put_u8(header, 0, 7)   # header's first byte is now 07`

### `put_u16(data, position, value)`
Writes a two-byte number at the position (changes the data), keeping only the lowest 16 bits.
`put_u16(header, 0, 513)   # header now starts 01 02`

### `put_u32(data, position, value)`
Writes a four-byte number at the position (changes the data), keeping only the lowest 32 bits.
`put_u32(header, 0, 1)   # header now starts 01 00 00 00`

### `band(a, b)`
Gives back the bitwise AND of two whole numbers.
`say band(12, 10)   # 8`

### `bor(a, b)`
Gives back the bitwise OR of two whole numbers.
`say bor(12, 10)   # 14`

### `bxor(a, b)`
Gives back the bitwise exclusive OR of two whole numbers.
`say bxor(12, 10)   # 6`

### `bnot(value, bits)`
Flips every bit of the value within a field `bits` wide (for example 8 for one byte) and gives back the result.
`say bnot(0, 8)   # 255`

### `shift_left(value, count)`
Gives back the whole number with its bits moved `count` places to the left (multiplied by 2 for each place).
`say shift_left(1, 4)   # 16`

### `shift_right(value, count)`
Gives back the whole number with its bits moved `count` places to the right (halved, rounding down, for each place).
`say shift_right(256, 4)   # 16`

## The web

The HTTP functions give back a map with `status` (such as 200 or 404), `body` (the reply as text, decompressed and decoded) and `headers` (a map). A reply with an error status is still given back normally; only a server that cannot be reached at all is an error. Requests give up after 30 seconds. When the body you send is a map or list, it is sent as JSON with the `Content-Type: application/json` header.

### `http_get(url, [headers])`
Sends a GET request, with an optional map of extra headers, and gives back the reply map.
`say http_get("https://example.com")["status"]   # 200`

### `http_post(url, body, [headers])`
Sends a POST request with the body (text, or a map/list sent as JSON) and gives back the reply map.
`say http_post("https://httpbin.org/post", {"name": "Ana"})["status"]   # 200`

### `http_request(method, url, [body], [headers])`
Sends a request with any method (`"PUT"`, `"DELETE"`, `"PATCH"` and so on) and gives back the reply map.
`say http_request("DELETE", "https://httpbin.org/delete")["status"]   # 200`

### `download(url, path, [headers])`
Saves the raw reply of a web address straight into a file (safe for images, PDFs and other binary files; waits up to 120 seconds). Gives back a map with `ok`, `status`, `bytes` (the size saved), `path` and `error`; a failed download gives `ok` as `no` instead of stopping the program.
`say download("https://example.com/logo.png", "logo.png")["ok"]   # yes`

### `render_html(input, output, [width], [height], [mode])`
Uses Google Chrome (or Chromium) without a window to turn an HTML file or web address into a PNG screenshot of `width` x `height` pixels (750 x 1050 if left out), or into a PDF when `mode` is `"pdf"`. Gives back a map with `ok`, `path`, `bytes` and `error`.
`say render_html("card.html", "card.png", 800, 600)["ok"]   # yes`
*Interpreter only.*

### `serve([port], handler)`
Starts a web server on the port (8080 if left out) and keeps running until you stop the program. For every request it calls the handler with a request map of `method`, `path`, `query` (a map), `headers`, `body`, `json` (the body read as JSON, when it is JSON), `form` (a map, for HTML form posts), `params` and `client` (the caller's address). The handler gives back text (sent as an HTML page) or a map with any of `status`, `body` (a map or list is sent as JSON), `type`, `headers`, `file` (send a file from disk; add `download: yes` to make the browser save it) or `bytes` (a list of 0-255 numbers). Instead of one function, the handler can be a map of routes such as `{"GET /users/:id": show_user, "/static/*": "public"}`: `:name` parts are put in `params`, and a text value serves files from that folder. An error in the handler is sent as a 500 reply.
`serve(8080, handle)   # Vanta server running on http://localhost:8080`

## Memory toolkit

These functions read and change the memory of a running program, the way a game trainer does: find the address that holds a value such as health, then write it or freeze it. Your own program always works; another program needs administrator rights (`sudo` on Mac and Linux), and macOS System Integrity Protection may still block it. Use them only with single-player, offline programs you own.

Where a function takes an optional `kind`, it can be `"int"` (4 bytes, the default), `"byte"`, `"long"` (8 bytes), `"float"` or `"double"`.

### `process_list()`
Gives back a list of the running programs, each a map with `pid` (process id) and `name`.
`say first(process_list())   # {"pid": 1, "name": "launchd"}`
*Interpreter only.*

### `find_pid(name)`
Gives back the process id of the first running program whose name contains the text (ignoring capitals), or 0 if none does.
`say find_pid("mygame")   # 4821`
*Interpreter only.*

### `my_pid()`
Gives back the process id of the Vanta program itself.
`say my_pid()   # 51234`

### `read_int(pid, address, [kind])`
Reads a number of the given kind from the program's memory at the address. An address that cannot be read is an error.
`say read_int(pid, 4370515968)   # 100`
*Interpreter only.*

### `write_int(pid, address, value, [kind])`
Writes a number of the given kind into the program's memory at the address and gives back `yes` if it worked, otherwise `no`.
`say write_int(pid, 4370515968, 999)   # yes`
*Interpreter only.*

### `read_float(pid, address)`
Reads a 4-byte decimal number from memory; the same as `read_int(pid, address, "float")`.
`say read_float(pid, 4370515972)   # 12.5`
*Interpreter only.*

### `write_float(pid, address, value)`
Writes a 4-byte decimal number into memory and gives back `yes` or `no`; the same as `write_int(pid, address, value, "float")`.
`say write_float(pid, 4370515972, 99.5)   # yes`
*Interpreter only.*

### `read_mem(pid, address, count)`
Reads `count` raw bytes from memory and gives them back as a list of numbers from 0 to 255 (an empty list if the memory cannot be read).
`say read_mem(pid, 4370515968, 4)   # [100, 0, 0, 0]`
*Interpreter only.*

### `write_mem(pid, address, numbers)`
Writes a list of byte numbers into memory and gives back `yes` or `no`.
`say write_mem(pid, 4370515968, [231, 3, 0, 0])   # yes`
*Interpreter only.*

### `mem_regions(pid)`
Gives back the readable memory areas of the program as a list of maps with `address` and `size`.
`say length(mem_regions(my_pid()))   # 412`
*Interpreter only.*

### `mem_scan(pid, value, [kind])`
Searches all readable memory (skipping areas over 64 MB) for the value and gives back the list of addresses where it was found (at most 200,000).
`let hits be mem_scan(pid, 100)   # every address holding the int 100`
*Interpreter only.*

### `mem_next(pid, addresses, value, [kind])`
Narrows down an earlier scan: gives back only those addresses from the list that now hold the new value. Repeat after the value changes in the program until one address is left.
`let hits be mem_next(pid, hits, 80)   # the addresses that changed to 80`
*Interpreter only.*

### `freeze(pid, address, value, [kind])`
Keeps writing the value to the address about 30 times a second in the background, so the program cannot change it. Gives back a freeze id for `unfreeze`.
`let lock be freeze(pid, address, 999)   # health stays at 999`
*Interpreter only.*

### `unfreeze(id)`
Stops a freeze started by `freeze`. Gives back `yes` if the id was active, otherwise `no`.
`unfreeze(lock)   # health can change again`
*Interpreter only.*

## Keyboard & mouse

These send key presses and mouse actions to the computer as if a person did them, and can watch for keys from any app. On a Mac the terminal running Vanta needs Accessibility (and Input Monitoring) permission the first time. Linux needs the `xdotool` program, and there `key_pressed`, `wait_key` and hotkeys cannot see keys.

Key names are letters (`"a"`), digits (`"1"`), `"space"`, `"enter"` (or `"return"`), `"tab"`, `"escape"` (or `"esc"`), `"backspace"`, `"delete"`, `"shift"`, `"ctrl"`, `"alt"` (`"option"`), `"cmd"` (Mac), `"left"`, `"right"`, `"up"`, `"down"` and `"f1"` to `"f12"`; Mac also accepts punctuation keys such as `";"` and `"/"`. An unknown key name is an error.

### `press_key(key)`
Presses and releases the key, then gives back `yes`.
`press_key("space")   # the active app receives a space`
*Interpreter only.*

### `key_down(key)`
Presses the key and holds it down (until `key_up`), then gives back `yes`. On Linux the key is pressed and released at once.
`key_down("shift")   # shift is held`

### `key_up(key)`
Releases a key held with `key_down` and gives back `yes`.
`key_up("shift")   # shift is released`
*Interpreter only.*

### `type_text(text)`
Types the text into the active app, character by character (any characters, not just keys on the keyboard), and gives back `yes`.
`type_text("Hello!")   # Hello! appears in the active app`
*Interpreter only.*

### `key_pressed(key)`
Gives back `yes` if the key is held down right now, in any app.
`say key_pressed("shift")   # no`

### `wait_key(key, [seconds])`
Waits until the key is freshly pressed and gives back `yes`; with a time limit, gives back `no` if the time runs out first.
`say wait_key("f1", 5)   # yes (F1 was pressed within 5 seconds)`
*Interpreter only.*

### `mouse_move(x, y)`
Moves the mouse pointer to the screen position (in points from the top-left corner) and gives back `yes`.
`mouse_move(400, 300)   # the pointer jumps to (400, 300)`
*Interpreter only.*

### `mouse_click([button])`
Clicks at the pointer's current position with `"left"` (the default) or `"right"` and gives back `yes`.
`mouse_click("right")   # right-click where the pointer is`
*Interpreter only.*

### `mouse_pos()`
Gives back the pointer's position as a map with `x` and `y`.
`say mouse_pos()   # {"x": 400, "y": 300}`
*Interpreter only.*

### `on_hotkey(key, function)`
Watches the key in the background and calls the function (with no values) each time the key is pressed, even while another app is in front. Gives back a hotkey id for `clear_hotkey`; the program must keep running (for example in a loop with `sleep`) for the hotkey to work.
`let hk be on_hotkey("f1", toggle_cheat)   # pressing F1 calls toggle_cheat()`
*Interpreter only.*

### `clear_hotkey(id)`
Stops a hotkey started by `on_hotkey`. Gives back `yes` if the id was active, otherwise `no`.
`clear_hotkey(hk)   # F1 no longer calls toggle_cheat`
*Interpreter only.*

<!-- 6.0 additions are appended below this line -->

## Concurrency

Vanta 6.0 runs functions at the same time as *tasks* and lets them talk through *channels*. Only one task runs
Vanta code at any instant (in the interpreter and in native builds alike), but a task that sleeps, waits for the
network, a process, a channel, a lock or another task lets the others run — so programs that wait a lot (servers,
crawlers, pipelines) really do run concurrently. For number-crunching on every core, use `run_parallel`.

Plain-English forms (each is the same as the function call next to it):

| You write | Same as |
|---|---|
| `let t be start fetch(url)` | `let t be spawn(fetch, url)` |
| `wait for t` / `let r be wait for t` | `wait(t)` |
| `send x to ch` | `send(ch, x)` |
| `let v be receive from ch` | `let v be receive(ch)` |
| `lock` … `end` | hold the program-wide lock for the block |
| `lock guard` … `end` | hold the lock `guard` (from `new_lock()`) for the block |

A `lock` block is released however it ends — normally, with `give back`, `stop`/`skip`, or an error. Locks are
re-entrant: a task may enter a lock it already holds.

### `spawn(function, [values...])`
Starts running `function(values...)` as a task and gives back the task straight away. `start f(x)` is the same.
`let t be spawn(download, "https://example.com")`

### `wait(task, [timeout])`
Waits until the task finishes and gives back its result. An error inside the task is raised here, so you can catch it with `attempt`/`rescue`. Give a list of tasks to wait for all of them (you get a list of results); give a process to wait for it to exit (you get its exit code). With a timeout in seconds, gives back nothing if it isn't finished by then.
`say wait for [start double(1), start double(2)]   # [2, 4]`

### `is_done(task)`
Has the task (or process) finished? Never waits.
`say is_done(t)   # no`

### `channel([capacity])`
Makes a channel: a queue that tasks use to hand values to each other safely. With a capacity, `send` waits while the channel is full; without one it never fills up.
`let jobs be channel(10)`

### `send(channel, value)`
Puts a value on a channel (`send value to channel`). Sending on a closed channel is an error. Also sends text or bytes over a socket or a websocket.
`send "job 1" to jobs`

### `receive(channel, [timeout])`
Takes the next value off a channel, waiting for one if it's empty (`receive from channel`). Gives back nothing once the channel is closed and empty, or when the timeout (seconds) passes. Waiting on an empty channel when no task or server is running is an error ("would wait forever") instead of a hang. On a socket, gives back the next chunk of text (up to the size given, default 65536 bytes; "" when the other side has closed); on a websocket, the next message.
`let v be receive(jobs, 2)`

### `new_lock()`
Makes a lock for `lock NAME … end` blocks, so only one task at a time runs code guarded by it.
`let guard be new_lock()`

### `run_parallel(function, list, [workers])`
Calls `function` on every item using several worker processes (one per CPU core by default) and gives back the results in order — real parallel CPU work. Results must be plain values (numbers, text, yes/no, nothing, lists, maps, bytes). Changes a worker makes to variables are not seen by the main program, and an error in any worker is raised here. Falls back to running one at a time where processes can't be forked (Windows, the browser).
`say run_parallel(square, [1, 2, 3, 4])   # [1, 4, 9, 16]`

## Handles: files, sockets, processes

Several 6.0 functions give back a *handle* — a task, channel, lock, socket, websocket, file, process, server or
database. `say` shows a handle as `<kind>` and `type_of` gives its kind (`"socket"`, `"file"`, ...). These
functions work on more than one kind:

### `close(handle)`
Closes a file, socket, websocket, channel, process, server or database. Closing twice is harmless.
`close(f)`

### `read_line(handle)`
Reads the next line from a file, socket or process (its output), without the line ending (`\n` or `\r\n`). Gives back nothing at the end.
`let line be read_line(f)`

### `read_all(handle)`
Reads everything that's left from a file, socket or process as text.
`say read_all(open_file("notes.txt"))`

### `write_to(handle, value)`
Writes text (as UTF-8) or bytes to a file, socket, or a process's input.
`write_to(f, "a line\n")`

### `receive_bytes(socket, [size])`
Like `receive` on a socket, but gives back bytes (up to `size`, default 65536).
`let chunk be receive_bytes(conn, 4096)`

## Networking

All of these work in native builds too; every blocking call lets other tasks run.

### `tcp_connect(host, port, [timeout])`
Opens a TCP connection and gives back a socket. The timeout (seconds) limits only the connecting; use `set_timeout` for reads. Fails with "could not connect to HOST:PORT: …".
`let s be tcp_connect("example.com", 80, 5)`

### `tcp_listen(port, [host])`
Listens for TCP connections on a port (0 picks a free one; see `socket_info`) and gives back a listening socket. Listens on every network interface unless you give a host such as "127.0.0.1".
`let server be tcp_listen(9000)`

### `accept(server, [timeout])`
Waits for the next connection on a listening socket and gives back a socket for it; nothing if the timeout passes.
`let conn be accept(server)`

### `set_timeout(socket, seconds)`
Makes reads and writes on the socket fail with "the connection timed out" after that long (nothing = wait forever).
`set_timeout(conn, 10)`

### `socket_info(socket)`
Gives back `{local_host, local_port, remote_host, remote_port}` (remote ones are nothing for a listening socket).
`say socket_info(server)["local_port"]   # 9000`

### `udp_open([port], [host])`
Opens a UDP socket bound to a port (0 or none = any free port).
`let u be udp_open(5000)`

### `udp_send(socket, host, port, data)`
Sends one UDP datagram (text or bytes).
`udp_send(u, "127.0.0.1", 5001, "ping")`

### `udp_receive(socket, [size], [timeout])`
Waits for one datagram and gives back `{data, host, port}`, or nothing if the timeout passes.
`let msg be udp_receive(u, 1024, 2)`

### `dns_lookup(host)`
Gives back the host's IP addresses (IPv4 and IPv6) as a list of text.
`say dns_lookup("localhost")   # ["::1", "127.0.0.1"]`

### `ws_connect(url, [headers])`
Opens a WebSocket connection to a `ws://` URL. Use `send`, `receive` (with an optional timeout; nothing when the server closes) and `close` on it. Text messages arrive as text, binary ones as bytes. (`wss://` is not supported yet.)
`let ws be ws_connect("ws://localhost:8080/chat")`

## The web server

`serve(port, handler)` (see *The web* above) runs a server until you stop the program; `start_server` runs one in
the background. A handler is either a function that takes a request map and gives back a page, or a **routes map**:

```
let routes be {"GET /": home, "GET /users/:id": show_user, "POST /items": add_item}
change routes["GET /static/*"] to "public"        # a folder of files
change routes["WS /chat/:room"] to chat            # a WebSocket endpoint
serve(8080, routes)
```

- A key is `"METHOD /path"` or just `"/path"` (any method). `:name` matches one path segment and lands in
  `request["params"]["name"]`; a final `*` matches the rest (`request["params"]["*"]`). The first matching route
  wins; no match gives 404. A `GET` route also answers `HEAD`.
- A text value serves static files from that folder (`index.html` for a folder; `..` is refused).
- A `WS` route upgrades the connection to a WebSocket and calls the function with `(ws, request)`; when it gives
  back, the connection closes. WebSocket handlers run at the same time as each other.
- The request map has `method`, `path`, `query` (a map; repeated keys give a list), `headers`, `body` (text),
  `params`, `json` (the body parsed when it's JSON, else nothing), `form` (a map for form posts) and `client` (IP).
- A handler gives back text (an HTML page), bytes, or a map: `status`, `body` (a map/list body is sent as JSON),
  `headers`, `type` (content type), `file` (send a file; add `"download": yes` to make it a download).
- Ordinary handlers take turns (one at a time), so they never race each other.

### `start_server(port, handler)`
Starts a web server in the background and gives back a server handle straight away (port 0 picks a free port).
`let web be start_server(0, routes)`

### `server_port(server)`
The port a server is listening on.
`say "http://localhost:" + server_port(web)`

### `stop_server(server)`
Stops a server started with `start_server` (the same as `close(server)`).
`stop_server(web)`

### `json_response(value, [status])`
A response map that sends `value` as JSON.
`give back json_response({"ok": yes}, 201)`

### `redirect(url, [status])`
A response map that sends the browser elsewhere (302 by default).
`give back redirect("/login")`

## Processes & environment

### `run_process(command, [options])`
Runs a command to the end and gives back `{output, error, code}` — its standard output, standard error and exit code. A text command runs through the shell; a list runs the program directly with those arguments (no shell quoting worries). Options: `input` (text sent to its standard input), `dir` (folder to run in), `env` (a map of extra environment variables), `timeout` (seconds; "the command timed out" after that).
`say run_process(["git", "status", "--short"])["output"]`

### `open_process(command, [options])`
Starts a command and gives back a process handle you can talk to while it runs: `write_to` its input, `read_line`/`read_all` its output, `close_input`, `process_errors`, `wait`, `is_done`, `kill_process`, `close`. Options: `dir`, `env`, and `merge_errors: yes` to read standard error mixed into the output.
`let p be open_process("python3 -i")`

### `close_input(process)`
Closes the process's standard input, so it sees the end of its input.
`close_input(p)`

### `process_errors(process)`
Reads everything the process wrote to standard error (waits until it closes it).
`say process_errors(p)`

### `kill_process(process)`
Stops the process at once.
`kill_process(p)`

### `process_id(process)`
The operating system's id (pid) for the process.
`say process_id(p)`

### `set_env(name, value)`
Sets an environment variable for this program and the commands it runs; `nothing` removes it.
`set_env("MODE", "test")`

### `env_vars()`
Every environment variable as a map, sorted by name.
`say keys(env_vars())`

### `on_signal(name, function)`
Calls `function(name)` when the program receives a signal: "INT" (Ctrl-C), "TERM", "HUP", "USR1", "USR2", "QUIT" or "ALRM". `nothing` restores the default. (Not on Windows.)
`on_signal("TERM", save_and_quit)`

### `send_signal(process_or_pid, name)`
Sends a signal to a process.
`send_signal(p, "TERM")`

### `exit([code])`
Ends the program right away with an exit code (0 by default).
`exit(1)`

## More files & folders

### `open_file(path, [mode])`
Opens a file and gives back a file handle, for files too big to read at once. Modes: "read" (default), "write" (empties the file), "append", "update" (read and write). Use `read_line`, `read_all`, `read_chunk`, `write_to`, `seek`, `tell` and `close` on it.
`let f be open_file("big.log")`

### `read_chunk(file, size)`
Reads up to `size` bytes from a file handle as text ("" at the end).
`let piece be read_chunk(f, 4096)`

### `read_chunk_bytes(file, size)`
Reads up to `size` bytes from a file handle as bytes.
`let header be read_chunk_bytes(f, 16)`

### `seek(file, position, [from])`
Moves to a byte position, counted from "start" (default), "current" or "end".
`seek(f, -100, "end")`

### `tell(file)`
The current byte position in a file handle.
`say tell(f)`

### `walk_dir(folder)`
Every file under a folder, in all its subfolders, as a sorted list of paths.
`say walk_dir("src")   # ["src/lib/util.va", "src/main.va"]`

### `glob(pattern)`
The paths matching a pattern, sorted: `*` and `?` match within a name, `[abc]`/`[!abc]` match one character, and `**` matches any number of folders. Names starting with `.` only match a pattern that starts with `.`.
`say glob("src/**/*.va")`

### `matches_pattern(name, pattern)`
Does a name match a `*`/`?`/`[...]` pattern (the same rules as `glob`)?
`say matches_pattern("report.txt", "*.txt")   # yes`

### `temp_file([ending])`
Makes a new empty file in the system's temp folder and gives back its path.
`let tmp be temp_file(".csv")`

### `temp_dir()`
Makes a new empty folder in the system's temp folder and gives back its path.
`let work be temp_dir()`

### `absolute_path(path)`
The full path, with `~`, `.` and `..` worked out.
`say absolute_path("/a/b/../c")   # /a/c`

### `current_dir()`
The folder the program is running in.
`say current_dir()`

### `change_dir(path)`
Changes the folder the program runs in.
`change_dir("/tmp")`

## Data

### `csv_parse(text, [delimiter])`
Reads CSV text into a list of rows (lists of text). Handles quoted fields, `""` inside quotes, and line breaks inside quotes; blank lines are skipped.
`say csv_parse("a,b\n1,\"x, y\"")   # [["a", "b"], ["1", "x, y"]]`

### `csv_format(rows, [delimiter])`
Turns a list of rows into CSV text, quoting fields that need it.
`say csv_format([["name", "note"], ["Ana", "says \"hi\""]])`

### `csv_read(path, [delimiter])`
Reads a CSV file into a list of rows.
`let rows be csv_read("data.csv")`

### `csv_write(path, rows, [delimiter])`
Writes a list of rows to a CSV file.
`csv_write("out.csv", [["a", "b"], [1, 2]])`

### `csv_read_maps(path, [delimiter])`
Reads a CSV file whose first row names the columns, giving a list of maps.
`for each row in csv_read_maps("people.csv")`

### `csv_write_maps(path, maps, [columns])`
Writes a list of maps as CSV with a header row (columns from the first map, or the list you give).
`csv_write_maps("people.csv", people)`

### `date_parts(timestamp, [time_zone])`
Gives back `{year, month, day, hour, minute, second, weekday (1 = Monday), day_name, month_name, yearday, zone, offset}` for a timestamp, in local time or in the named time zone ("Europe/Paris", "UTC", ...).
`say date_parts(now())["day_name"]`

### `make_date(year, month, day, [hour], [minute], [second], [time_zone])`
The timestamp for a date and time (local time, or the named zone). Out-of-range values roll over (February 30 is March 1 or 2).
`let launch be make_date(2026, 10, 21, 9, 0, 0, "UTC")`

### `days(n)` · `hours(n)` · `minutes(n)`
That many days / hours / minutes in seconds, for date arithmetic.
`let deadline be now() + days(3)`

### `format_duration(seconds)`
A length of time as short text.
`say format_duration(93784)   # 1d 2h 3m 4s`

### `timezone()`
The local time zone's name (e.g. "America/New_York").
`say timezone()`

`format_date(stamp, [pattern], [time_zone])` and `parse_date(text, [pattern], [time_zone])` (under *Time & dates*) also take a time zone in 6.0.

### `regex_search(text, pattern)`
Finds the first match and gives back `{match, start, end, groups}` (character positions; groups that didn't take part are nothing), or nothing.
`say regex_search("order #42", "#([0-9]+)")["groups"]   # ["42"]`

### `regex_split(text, pattern)`
Splits text everywhere the pattern matches (captured groups are kept in the result).
`say regex_split("a1b22c", "[0-9]+")   # ["a", "b", "c"]`

### `regex_escape(text)`
Escapes the characters that mean something in a pattern, so the text matches literally.
`say regex_escape("1+1=2")   # 1\+1=2`

### `compress(data)` · `decompress(bytes)`
zlib compression: text (as UTF-8) or bytes in, bytes out, and back.
`say bytes_to_text(decompress(compress("hello")))   # hello`

### `gzip(data)` · `gunzip(bytes)`
The same with the gzip format (what .gz files and web servers use).
`write_binary("notes.txt.gz", gzip(read_file("notes.txt")))`

### `bytes_to_text(bytes)`
Decodes bytes as UTF-8 text.
`say bytes_to_text(bytes([104, 105]))   # hi`

### `sha1(data)` · `hmac(key, message, [algorithm])`
SHA-1 as hex, and an HMAC signature as hex (algorithm "sha256" by default, or "sha1" / "md5"). `md5` and `sha256` (above) accept bytes as well as text in 6.0.
`say hmac("secret", "message")`

### `uuid()`
A new random UUID (version 4).
`say uuid()   # e.g. 3f1c9a2e-8b4d-4f6a-9c1e-2d7b5a0e4c11`

### `random_seed(n)`
Makes `random`, `random_float`, `shuffle` and `pick` repeat the same sequence — the same numbers in the interpreter and in native builds.
`random_seed(42)`

### `gcd(a, b, ...)` · `lcm(a, b, ...)`
Greatest common divisor / least common multiple of whole numbers (or of one list).
`say gcd(12, 18)   # 6`

### `factorial(n)`
n! for a whole number of 0 or more.
`say factorial(10)   # 3628800`

### `isqrt(n)`
The whole-number square root (rounded down).
`say isqrt(17)   # 4`

### `mean(list)` · `median(list)` · `mode(list)`
The average, the middle value (the average of the middle two for an even count), and the most common value.
`say median([3, 1, 4, 1, 5])   # 3`

### `variance(list)` · `stdev(list)`
Sample variance and standard deviation (need at least two values).
`say stdev([2, 4, 4, 4, 5, 5, 7, 9])`

### `db_open(path)`
Opens (or creates) an SQLite database file — ":memory:" for one that lives only while the program runs — and gives back a database handle. Every statement commits on its own.
`let db be db_open("app.db")`

### `db_query(db, sql, [parameters])`
Runs a query and gives back its rows as a list of maps (column name → value). Use `?` with a list of parameters or `:name` with a map — never glue values into the SQL yourself.
`say db_query(db, "select * from users where age > ?", [30])`

### `db_execute(db, sql, [parameters])`
Runs a statement that changes data and gives back how many rows changed. Without parameters it may hold several statements separated by `;`.
`db_execute(db, "insert into users (name, age) values (:n, :a)", {"n": "Ana", "a": 31})`

### `db_last_id(db)`
The row id of the last row inserted.
`say db_last_id(db)`

## Standard modules

These are written in Vanta and live in `lib/`; `import` them by name. They work in native builds too.

### `import "collections"`
- `Stack()` — `push(x)`, `pop()`, `peek()`, `size()`, `is_empty()`, `to_list()` (top first).
- `Queue()` — first in, first out: `push(x)`, `pop()`, `peek()`, `size()`, `is_empty()`, `to_list()`.
- `Deque()` — both ends: `push_front(x)`, `push_back(x)`, `pop_front()`, `pop_back()`, `peek_front()`, `peek_back()`, `size()`, `is_empty()`, `to_list()`.
- `Heap([before])` — smallest first (or ordered by `before(a, b)` → yes when a comes first): `push(x)`, `pop()`, `peek()`, `size()`, `is_empty()`, `to_list()` (in order).
- `PriorityQueue()` — `push(item, priority)`, `pop()` gives the lowest priority first (ties in arrival order), `peek()`, `size()`, `is_empty()`.
- `count_items(list)` → `{value: count}`; `group_by(function, list)` → `{key: [values]}`.
- Popping or peeking an empty collection is an error such as "the stack is empty".

`let s be Stack()` · `s.push(1)` · `say s.pop()   # 1`

### `import "strings"`
`words(text)`, `center(text, width, [fill])`, `wrap(text, width)` (a list of lines), `truncate(text, width, [tail])`, `indent(text, [prefix])`, `dedent(text)`, `is_blank(text)`, `is_digits(text)`, `is_letters(text)`, `reverse_text(text)`, `count_of(text, piece)`, `between(text, start, finish)`, `strip_prefix(text, prefix)`, `strip_suffix(text, suffix)`, `squeeze(text)`, `snake_case(text)`, `kebab_case(text)`, `camel_case(text)`, `slugify(text)`, `fill_template(text, values)` (replaces `{name}` with `values["name"]`).

`say slugify("Hello, World!")   # hello-world`

### `import "cli"`
`parse_args(args, spec)` reads command-line options: `spec` maps each option name to its default, and the default's kind decides how it's read — yes/no is a flag (`--verbose`, `--no-verbose`), a number must be a number (`--count 3` or `--count=3`), text is taken as is. Each option also gets a one-letter form (`-v`) when its first letter is unique. Other words land in `"args"`, everything after `--` too, and `-h`/`--help` sets `"help"`. Unknown options and missing values are errors. `arg_usage(program, spec)` gives the help text.

`let opts be parse_args(arguments(), {"verbose": no, "count": 1})`

### `import "log"`
`log_debug(message)`, `log_info(message)`, `log_warn(message)`, `log_error(message)` print `2026-10-21 14:30:05 INFO  message` when the level is high enough. `log_level("debug" | "info" | "warn" | "error" | "off")` (default "info"), `log_to_file(path)` (also append lines to a file), `log_show_time(yes/no)`, `log_quiet(yes/no)` (stop printing to the screen), `log_lines()` (everything logged so far). Safe to use from several tasks at once.

`log_warn("disk almost full")`

The older modules are still there: `import "lists"`, `"math"`, `"random"` and `"text"`.

