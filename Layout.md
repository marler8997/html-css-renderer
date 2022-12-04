# Layout

My notes on HTML Layout.

## Differences between Horizontal and Vertical

Who determines the size of things in an HTML/CSS layout?
Here's my understanding of the defaults so far:

```css
/*[viewport]*/ {
    width: [readonly-set-for-us];
    height: [readonly-set-for-us];
}
html {
    width: auto; 
    height: max-content; /* is this right, maybe fit or min content */
}
body {
    width: auto;
    height: max-content; /* is this right, maybe fit or min content */
    margin: 8; // seems to be the default in chrome at least
}
```

My understanding is that for `display: block` elements, `width: auto` means `width: 100%`.
Note that percentage sizes are a percentage of the size of the parent container.
This means the size comes from the parent container rather than the content.

From the defaults above, the top-level elements get their width from the viewport and their
height from their content, meaning that HTML behaves differently in the X/Y direction by default.

> NOTE: for `display: inline-block` elements, `width: auto` means `max-content` I think?
        you can see this by setting display to `inline-block` on the body and see that its
        width will grow to fit its content like it normally does in the y direction.

Also note that `display: flex` seems to behave like `display: block` in this respect, namely,
that by default its width is `100%` (even for elements who default to `display: inline-block` like `span`)
and its height is `max-content` (I think?).

NOTE: fit-content is a value between min/max content determined by this conditional:
```
if available >= max-content
    fit-content = max-content
if available >= min-content
    fit-content = available
else
    fit-content = min-content
```

## Flexbox

There's a "main axis" and "cross axis".
Set `display: flex` to make an element a "flex container".
All its "direct children" become "flex items".

### Flex Container Properties

#### flex-direction: direction to place items

- row: left to right
- row-reverse: right to left
- column: top to bottom
- coloumn-reverse: bottom to top

#### justify-content: where to put the "extra space" on the main axis

- flex-start (default): items packed to start so all "extra space" at the end
- flex-end: items packed to end so all "extra space" at the start
- center: "extra space" evenly split between start/end
- space-between: "extra space" evenly split between all items
- space-evenly: "exta space" evently split between and around all items
- space-around (dumb): like space-evenly but start/end space is halfed

#### align-items: how to align (or stretch) items on the cross axis

- flex-start
- flex-end
- center
- baseline: all items aligned so their "baselines" align
- stretch


By default flexbox only has a single main axis, the following properties apply to flex containers
that allow multiple lines:

#### flex-wrap

- nowrap (default): keep all items on the same main axis, may cause overflow
- wrap: allow multiple "main axis"
- wrap-reverse: new axis are added in the "opposite cross direction" of a normal wrap
                for example, for flex-direction "row", new wrapped lines would go
                on top of the previous line instead of below.

### align-content: where to put the "extra space" on the cross axis

Note that this is only applicable when wrapping multiple lines.

Same values as "justify-content" except it doesn't have "space-evenly"
and it adds "stretch", which is the default.

#### flex-flow

Shorthand for `flex-direction` and `flex-wrap`.

### Flex Item Properties

#### order: set the item's "order group"

All items in a lower "order group" come first.
The default "order group" is 0.
Order can be negative.

#### align-self: how to align (or strech) this item on the cross axis

Same as "align-items" on the container except it affects this one item.


### Flex Layout Algorithm

See if I can come up with a set of steps that can be done independently of each other to layout a flexbox.

- Step ?: if there is "extra space" on the main axis, position items based on justify-content
