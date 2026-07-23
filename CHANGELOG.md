# Changelog

## 1.0.0 (2026-07-23)


### Features

* add emacs like compile ([29ef0a1](https://github.com/ArminIrannejad/tarminal.nvim/commit/29ef0a1c71f30a2b77e5416acedef3bbd329f688))
* configurable error pattern table for error detection ([b8bd7e7](https://github.com/ArminIrannejad/tarminal.nvim/commit/b8bd7e7904fb173df77fea4b868df3e3c5f095e9))
* introspect terminal cwd/state on macos ([3a37dba](https://github.com/ArminIrannejad/tarminal.nvim/commit/3a37dba9f176e058c721f78ab2dbd690121cd875))
* precise busy check on macos/bsd via ps tpgid ([ff1a725](https://github.com/ArminIrannejad/tarminal.nvim/commit/ff1a725c2c4b354147c77b3771d4889b997b4d69))
* severity-aware navigation, highlighting, and quickfix ([dba1f0a](https://github.com/ArminIrannejad/tarminal.nvim/commit/dba1f0a9bc4a9d96d23f74e6181bb949473a108a))


### Bug Fixes

* add guard for running on non term ([b4f7b47](https://github.com/ArminIrannejad/tarminal.nvim/commit/b4f7b478ea61fe7c410e3f9e1b46d4a26caa8f0c))
* bracketed paste option ([3df280f](https://github.com/ArminIrannejad/tarminal.nvim/commit/3df280f381fae0480af4fb8893659913ea826dc3))
* busy term ([809322d](https://github.com/ArminIrannejad/tarminal.nvim/commit/809322d55bcf0e948801971009f1de1a7e68c440))
* check if time binary exist ([93fb82b](https://github.com/ArminIrannejad/tarminal.nvim/commit/93fb82bf2aafb20802c605cf7ef4e1d4a217ad22))
* Clean up old highlight ([02df322](https://github.com/ArminIrannejad/tarminal.nvim/commit/02df3220472787c16a4b7fa8e60eb4c04db57f1d))
* clean up split when shell fails to start ([366694b](https://github.com/ArminIrannejad/tarminal.nvim/commit/366694b67c5fc3fae31e55797321b4600f4e87b2))
* completion based errors ([4618bac](https://github.com/ArminIrannejad/tarminal.nvim/commit/4618bacc0c06b5cd076cd8c8d2e9259ffb4c0af3))
* cut blockwise selections at screen columns ([1cd82c2](https://github.com/ArminIrannejad/tarminal.nvim/commit/1cd82c24616910fe456251564af1227e83a8795c))
* don't clobber the last run when a file has no runner ([89c4ff2](https://github.com/ArminIrannejad/tarminal.nvim/commit/89c4ff268bae396cf8016f29b3a5a53fa975adeb))
* don't crash jumping to a file-only error location ([4fbb176](https://github.com/ArminIrannejad/tarminal.nvim/commit/4fbb176e48984c033079626f9d99ba41033b6346))
* don't interupt busy term ([5f6a32a](https://github.com/ArminIrannejad/tarminal.nvim/commit/5f6a32a7c689df90dabf1458bb65cb6cffe447de))
* don't let a pre-run busy stop watcher ([c15fbdc](https://github.com/ArminIrannejad/tarminal.nvim/commit/c15fbdc5344889cd5360b3a1effc10c26c5453fb))
* don't send repl input to the bare shell when the repl isn't running ([55c68d8](https://github.com/ArminIrannejad/tarminal.nvim/commit/55c68d8af11f5181561d1548573205a7f1b11360))
* fix busy term test ([13fcc75](https://github.com/ArminIrannejad/tarminal.nvim/commit/13fcc75498f8ea9d160524d3351b8215359bb2b2))
* fix some language compile output without link ([fccd687](https://github.com/ArminIrannejad/tarminal.nvim/commit/fccd6873618639c5c8c0def4ad688c49af623927))
* fix time ([e8efd46](https://github.com/ArminIrannejad/tarminal.nvim/commit/e8efd46d7643a1c5bbecf1c2bd79ca9b1898d7a9))
* fresh busy check in run guard so no stale ([ebc8622](https://github.com/ArminIrannejad/tarminal.nvim/commit/ebc8622aa51bc1702845a01949760d5c21006964))
* hide the terminal when quickfix closes it as the last window ([a05167c](https://github.com/ArminIrannejad/tarminal.nvim/commit/a05167c1cb72a9a992578f1f70db6b8599caaf8d))
* keep error watcher alive while command is busy ([bf1e009](https://github.com/ArminIrannejad/tarminal.nvim/commit/bf1e00913d16ffd98f2f81c4fcc0320bd78ed855))
* make runners and term fully configureable ([0e24eba](https://github.com/ArminIrannejad/tarminal.nvim/commit/0e24ebacba4949d6dd908ffd76f5714af0c50744))
* no early return from non-file buff ([0c81deb](https://github.com/ArminIrannejad/tarminal.nvim/commit/0c81deb8392e218c6aee025d3492a54c92b59b4e))
* only run error nav on tarminal's own terminals ([e7ca817](https://github.com/ArminIrannejad/tarminal.nvim/commit/e7ca817514878d2c0052006cdccf68a3753a54d6))
* parse error paths containing parentheses ([3eb66b4](https://github.com/ArminIrannejad/tarminal.nvim/commit/3eb66b4fe903402da8665bf723e83d95cc3e3b91))
* prepend user error_patterns instead of index-merging them ([dca2cac](https://github.com/ArminIrannejad/tarminal.nvim/commit/dca2cac02d0d94909afaff6e437ab8a5ce3b75dc))
* prepend user error_patterns instead of index-merging them ([a2f36ff](https://github.com/ArminIrannejad/tarminal.nvim/commit/a2f36ff5d28429730a633d91a1f7d65ba17ea1c6))
* preserve shell quoting in exec and always prompt ([a1b1547](https://github.com/ArminIrannejad/tarminal.nvim/commit/a1b15475a86b4153c6eb4fe410f4dec01f750697))
* prompt exec instead of rerun on non-files ([9c1cb5e](https://github.com/ArminIrannejad/tarminal.nvim/commit/9c1cb5ed5160044f2538e33a86201e9f6fe03437))
* repl bracketed paste for ghci and add more repls ([ef62fc6](https://github.com/ArminIrannejad/tarminal.nvim/commit/ef62fc627c7fcc7e42fc69f2cf3ec062dfd5c225))
* resolve error paths glued to a prefix by a bracket ([ad48bd3](https://github.com/ArminIrannejad/tarminal.nvim/commit/ad48bd307d3cb5b36ab5bde799ec6ed6e58cef6e))
* scrollable also for success ([49fa408](https://github.com/ArminIrannejad/tarminal.nvim/commit/49fa4087587ccf9d0b9715e242fc7ff17d287ca0))
* update on resize ([ba8d556](https://github.com/ArminIrannejad/tarminal.nvim/commit/ba8d55614eeb8d6aac342c06cbb8675f21267a62))


### Performance Improvements

* cache macos-outs so output cant respawn lsof ([01a58b5](https://github.com/ArminIrannejad/tarminal.nvim/commit/01a58b5e510ff979d4ef32dfefbe63aa0f80f102))
