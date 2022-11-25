# Html Css Renderer

* write a tool that will parse html/css and dump all the features they use


# Existing Html/CSS Renderers?

Can we leverage an existing HTML/CSS Renderer?
How easy to build them?
Are they cross-platform?
How easy to instantate them in our own window?

Here are some options:

- WebKit
- Blink
- Gecko

### WebKit

https://github.com/WebKit/WebKit

I think this works on all 3 platforms (Mac/Windows/Linux).

Looks like for linux they support GTK or EFL?

- Source Repo is 14G, that's big!

### Flow

Summary: Proprietary, meh.

### Quantum (used by Firefox)

Did this circumvent the Gecko engine in 2016?

### Goanna

Summary: not designed to be used outside of XUL applications

Used by the "Pale Moon" Browser
Might be Windows/Linux only? (no Mac?)
Fork of Mozilla's Gecko in 2015.

http://www.moonchildproductions.info/goanna.shtml

> Where can I find the source?
> Goanna does not have a stand-alone source, since it can't be used as a stand-alone library. If you want to make use of the engine, you can build your application on the Unified XUL Platform (UXP).
The engine is an integral part of that platform, the source of which can be found on GitHub.

NOTE: link to github does not work, looks like it's moved here: https://repo.palemoon.org/MoonchildProductions/UXP

### K-Meleon (designed specifically for Win32)

### Qutebrowser

### Midori

### Comodo IceDragon

### Dillo (might be linux/unix specific)

### NetSurf (might be linux/unix specific)
