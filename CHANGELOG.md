# Changelog

## [0.3.0](https://github.com/ArminIrannejad/tarminal.nvim/compare/v0.2.0...v0.3.0) (2026-08-03)


### ⚠ BREAKING CHANGES

* require Neovim 0.10
* stop timing runs by default

### Features

* add :checkhealth tarminal ([1881f42](https://github.com/ArminIrannejad/tarminal.nvim/commit/1881f42d5814aeee79b64af607291c1f5b16abd8))
* add clear_run to wipe the terminal before each run ([eb32d41](https://github.com/ArminIrannejad/tarminal.nvim/commit/eb32d417e1d34fa755641d95da205dcbde8a0a8a))
* add fish shell integration and clear setup noise ([848f6b6](https://github.com/ArminIrannejad/tarminal.nvim/commit/848f6b66b4edf5ca6bf64a772e77c8932d15efe0))
* clear run default ([a6ae6b1](https://github.com/ArminIrannejad/tarminal.nvim/commit/a6ae6b10f578ff466454e0ed539548199a221d0b))
* clear the terminal before every run ([2838bc1](https://github.com/ArminIrannejad/tarminal.nvim/commit/2838bc17500a3077e9bd1b0a73876cebc8dfe102))
* close_on_jump closes the terminal after a jump ([a01ac13](https://github.com/ArminIrannejad/tarminal.nvim/commit/a01ac132e628a2ef2759504ae431a00fef296b03))
* require Neovim 0.10 ([531e2d8](https://github.com/ArminIrannejad/tarminal.nvim/commit/531e2d8122d5a0576a82abeb3e9c56c59b54b040))
* stop timing runs by default ([cd245e2](https://github.com/ArminIrannejad/tarminal.nvim/commit/cd245e2e9a75795ec5108d58677fcf4a6ed1ea54))


### Bug Fixes

* bound a wrapped line scan so the walk always advances ([54bd331](https://github.com/ArminIrannejad/tarminal.nvim/commit/54bd331f9d694f70283a56868d06346c959a247b))
* cancel pending prompt input before a run ([bf3d1ed](https://github.com/ArminIrannejad/tarminal.nvim/commit/bf3d1ed223e5f3eb3bb42d18f6218eb5693be709))
* clear the prompt line before a cancelled run ([d3b1ce4](https://github.com/ArminIrannejad/tarminal.nvim/commit/d3b1ce4f6a2ff951754abea8e40626457d5d7dd1))
* complete exec with paths only, not $PATH commands ([f37c8ac](https://github.com/ArminIrannejad/tarminal.nvim/commit/f37c8acdcbe0acd1e83bb6769182be15a9556645))
* complete files and commands for :Tarminal exec ([a3aba9e](https://github.com/ArminIrannejad/tarminal.nvim/commit/a3aba9e8b48a7bc66fcdf2759281bf88855bd7f4))
* complete files and commands for exec ([19366d9](https://github.com/ArminIrannejad/tarminal.nvim/commit/19366d96fa5f38757f15fdd0c65eed8a78cdd249))
* drop the run number from the banner ([589bc6e](https://github.com/ArminIrannejad/tarminal.nvim/commit/589bc6e550e320d4d0f1f671327ecaa5b682705c))
* jump window reuse ([6144751](https://github.com/ArminIrannejad/tarminal.nvim/commit/6144751f9c3220ba70beb9d63c6db613f6b31b3c))
* keep the watcher alive while the shell has a child ([290a17c](https://github.com/ArminIrannejad/tarminal.nvim/commit/290a17cae59614055bfa6ccc67213e9e00e10721))
* nil send_selection error ([8317761](https://github.com/ArminIrannejad/tarminal.nvim/commit/83177619463576b94f386974850297542237557a))
* register highlights and autocmds without setup() ([676bc79](https://github.com/ArminIrannejad/tarminal.nvim/commit/676bc7900a52b7aff6c55867e3e9c2cb32eb1660))
* reuse an oil-style window for jumps instead of splitting ([94f6c24](https://github.com/ArminIrannejad/tarminal.nvim/commit/94f6c242d50594b7dff58cbc1821cd9cfd0efc7c))
* run input safety ([75e2687](https://github.com/ArminIrannejad/tarminal.nvim/commit/75e26876b3f94f79dd4fc3090bbb5829751eb7b8))
* split when a window refuses the jump buffer ([5efda6f](https://github.com/ArminIrannejad/tarminal.nvim/commit/5efda6ffaf20f782145b7dba929eae2fc2e89982))
* use the wrapped line fallback for quickfix too ([23e2e92](https://github.com/ArminIrannejad/tarminal.nvim/commit/23e2e9281662c52d69405001705bdc874610a635))

## [0.2.0](https://github.com/ArminIrannejad/tarminal.nvim/compare/v0.1.1...v0.2.0) (2026-07-26)


### ⚠ BREAKING CHANGES

* drop Windows support

### Features

* auto-enable shell integration ([c9f3a3d](https://github.com/ArminIrannejad/tarminal.nvim/commit/c9f3a3d8cbb4644747eee78f11d9df5b33775d79))
* bsd cwd via procstat ([f2163d1](https://github.com/ArminIrannejad/tarminal.nvim/commit/f2163d1b8cdf78d2b51f9f683cca2c15a08ee46e))
* drop Windows support ([2a63fc3](https://github.com/ArminIrannejad/tarminal.nvim/commit/2a63fc30c44b141957164bfb923cc249ea2b2b1c))
* native Windows cwd probe via PEB read ([50978cd](https://github.com/ArminIrannejad/tarminal.nvim/commit/50978cd50700d4bd18cd3c86f381a15aeebdaf1a))
* track cwd via osc 7 ([0639e6e](https://github.com/ArminIrannejad/tarminal.nvim/commit/0639e6e499dc7fd62d82f5832db5aa34c2756c2b))
* windows process detection ([a97c90d](https://github.com/ArminIrannejad/tarminal.nvim/commit/a97c90d28909c5e72e3d6223b0f16e3d60b5f592))


### Bug Fixes

* bypass cached busy probe on Windows for fresh checks ([0d0adab](https://github.com/ArminIrannejad/tarminal.nvim/commit/0d0adab519badf9c52118efc71fa4afeb63554c8))
* ignore conhost in the Windows busy probe ([2fd47fc](https://github.com/ArminIrannejad/tarminal.nvim/commit/2fd47fc05013e120003e056bcb1e6b055e3b8262))
* keep a spaced shell path as one argv entry ([fc8e56f](https://github.com/ArminIrannejad/tarminal.nvim/commit/fc8e56f449b2843541dedc03979987c0389fbb5a))
* keep drive letters in Windows error paths ([3c065d3](https://github.com/ArminIrannejad/tarminal.nvim/commit/3c065d3a26cb2c49f9392d09458c001f6a36dbb9))
* keep severity and unglue diagnostics in error parsing ([f5bb87b](https://github.com/ArminIrannejad/tarminal.nvim/commit/f5bb87b769f8b948c59af97856d9e7d6cf741cc2))
* match .exe and backslash-path compilers ([732fc3b](https://github.com/ArminIrannejad/tarminal.nvim/commit/732fc3be195eed6eb074e0d0093f7b3641c4f698))
* off by one exclusive ([9235b99](https://github.com/ArminIrannejad/tarminal.nvim/commit/9235b99121e3cbbce1526be85d1b6a6cab9dba27))
* quote for the POSIX terminal, not &shell ([cc2a5fe](https://github.com/ArminIrannejad/tarminal.nvim/commit/cc2a5fe50038a98784bd437e14bf46890ef6d045))
* translate MSYS and Cygwin OSC 7 paths on Windows ([2891018](https://github.com/ArminIrannejad/tarminal.nvim/commit/28910189b747fad75bd9dc2c665f1f4938f841ae))
* treat UNC diagnostic paths as absolute ([207b3b6](https://github.com/ArminIrannejad/tarminal.nvim/commit/207b3b699af167a8ce6eec3b3e85a04168169331))
* windows path resolution ([79d9a93](https://github.com/ArminIrannejad/tarminal.nvim/commit/79d9a93cfd69db663eb20cb49c0b20e5c400e758))

## [0.1.1](https://github.com/ArminIrannejad/tarminal.nvim/compare/v0.1.0...v0.1.1) (2026-07-23)


### Bug Fixes

* keep run banner pinned to window top ([e2b456b](https://github.com/ArminIrannejad/tarminal.nvim/commit/e2b456b667dd8b815ba18a6466aaac1551e170ba))
* keep run banner pinned to window top ([61f6a24](https://github.com/ArminIrannejad/tarminal.nvim/commit/61f6a24c7527f505d414ddc6e7d6bb6210292bec))

## 0.1.0 (2026-07-23)


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
