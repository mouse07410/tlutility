---
title: TeX Live Utility
layout: default
---

## What Is This?

TeX Live Utility is a Mac OS X graphical interface for [TeX Live Manager](http://www.tug.org/texlive/tlmgr.html), which is a tool provided with [TeX Live](http://www.tug.org/texlive/) 2008 and later, for updating, installing, and otherwise managing TeX Live. TeX Live Utility aims to provide a native Mac OS X interface for the most commonly used functions of the TeX Live Manager command-line tool.

## Functionality

The present subset of commands is as follows:

  * Set paper size for all TeX programs
  * Update packages (all or subset)
  * Install and remove packages (all or subset)
  * Show details for individual packages (including texdoc results)
  * Set a mirror URL for command-line tlmgr usage
  * List and restore backups

See [Getting Started](GettingStarted.html) for screenshots and more specific details.

## Why Use This?
Why use this program when you can use the command line tlmgr or its built-in Perl/Tk GUI? TeX Live Utility performs TeX Live infrastructure updates using the [Disaster Recovery script](http://www.tug.org/texlive/tlmgr.html), which avoids problems with tlmgr removing itself while updating. TeX Live Utility also provides a native OS X user interface, and does not require installation of Perl/Tk (which can be complicated).

## Requirements

  * Mac OS X Snow Leopard 10.6.8 or greater
  * [TeX Live](http://www.tug.org/texlive/) installed via [MacTeX](http://www.tug.org/mactex) or the standard Unix install


## Versioning Notes
TeX Live Utility 0.74 and earlier will work with TeX Live 2008 and 2009. Current versions of TeX Live Utility require TeX Live 2009 or later, due to changes in the tlmgr tool itself.

If you are stuck using Mac OS X Leopard 10.5.7 (e.g, you are using a PowerPC system), you can use TeX Live Utility 1.03 or earlier. Unfortunately, Apple made it too hard to keep supporting 10.5.

## Support
If you have a bug report or feature suggestion, please use the issue tracker (Issues tab on this page). There is also a [Mailing List](http://tug.org/mailman/listinfo/tlu) dedicated to discussion of TeX Live Utility where you can post questions, comments, or discuss ideas for development. Subscription isn't required if you just have a question; you can [email](mailto:tlu@tug.org) us directly.

## Beta Testing
There is usually a beta release available on the [Releases Page](https://github.com/amaxwell/tlutility/releases) which is more recent than the latest official release. These are likely to have bugs, so any testing and feedback is appreciated.

Instructions for downloading the source and compiling it are [available here](Building.html).

## License
TeX Live Utility is free software, and released under the [BSD License](License.html)