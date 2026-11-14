# Changelog

## [0.2.1](https://github.com/leonqadirie/soundcheck/compare/v0.2.0...v0.2.1) (2026-11-14)


### Bug Fixes

* treat compound connected? conditions as guards ([#21](https://github.com/leonqadirie/soundcheck/issues/21)) ([81b2645](https://github.com/leonqadirie/soundcheck/commit/81b2645817e23a02666bae653954bd4683f48570)), closes [#20](https://github.com/leonqadirie/soundcheck/issues/20)

## [0.2.0](https://github.com/leonqadirie/soundcheck/compare/v0.1.0...v0.2.0) (2026-11-13)


### ⚠ BREAKING CHANGES

* under Credo, files in test directories no longer enter the graph. A project that sets a check's excluded_paths to [] to analyze LiveViews under test/ must also set the plugin's graph_excluded_paths, for example {Soundcheck, [graph_excluded_paths: []]}.

### Bug Fixes

* leave test files out of the graph Credo builds ([#18](https://github.com/leonqadirie/soundcheck/issues/18)) ([88c6951](https://github.com/leonqadirie/soundcheck/commit/88c695179a31bb1e6e2f4f2838538bb621210c3f))
* read one set of default sources in every mode ([#17](https://github.com/leonqadirie/soundcheck/issues/17)) ([bcfc2c6](https://github.com/leonqadirie/soundcheck/commit/bcfc2c6e3e53ed0af6596e8421eef0f77a5ecc0d))
* stop counting atom values as assigned keys ([#13](https://github.com/leonqadirie/soundcheck/issues/13)) ([97e1757](https://github.com/leonqadirie/soundcheck/commit/97e175716d39830edae3ea30ef1f3a97ce7da50b))

## 0.1.0 (2026-11-11)


### Features

* add a benchee suite for local A/B performance comparisons ([9a1106e](https://github.com/leonqadirie/soundcheck/commit/9a1106e9b7b22d80d68a2c1343e6572bd2d776a8))
* add an error-tolerant HEEx parser and ~H sigil discovery ([3ecde09](https://github.com/leonqadirie/soundcheck/commit/3ecde09b5035bf9e5666bb14e76647524821663f))
* add mix soundcheck to run the checks without Credo ([fbd1961](https://github.com/leonqadirie/soundcheck/commit/fbd196180ff4124f232c98ea7bdafeb64ee2e9c9))
* add the Igniter installer ([bb14cee](https://github.com/leonqadirie/soundcheck/commit/bb14cee933bf4b8ca01a38b281c9da368e794872))
* add the run cache and compute-once server ([c181c08](https://github.com/leonqadirie/soundcheck/commit/c181c086ce80818a89687ca060d53b3609153eef))
* build the per-run graph and run checks as a Credo plugin ([38e0a55](https://github.com/leonqadirie/soundcheck/commit/38e0a55a038605f858dbd52a7a3ebffad97db653))
* check assigns and component attrs against their reads ([94d834b](https://github.com/leonqadirie/soundcheck/commit/94d834b33cad767cb36fa20a3a8e70e11eecaa02))
* check JavaScript hooks against templates and server pushes ([3cf3910](https://github.com/leonqadirie/soundcheck/commit/3cf39107576d16b3ffd7acc6a1a2922fca56ef44))
* check messages, async results, and callback matches ([e916d4f](https://github.com/leonqadirie/soundcheck/commit/e916d4f78938e2608f128127b1c6b62bdcda0c2a))
* check navigation, mount hooks, and authorization ([d4ab6e6](https://github.com/leonqadirie/soundcheck/commit/d4ab6e62dbd9968f09f3cb12a0de9b20cf076f74))
* check streams and uploads ([a567983](https://github.com/leonqadirie/soundcheck/commit/a56798319eeab9497b5bf2ea5fb4740fc1b9ddde))
* check template events against handle_event clauses ([06fe45a](https://github.com/leonqadirie/soundcheck/commit/06fe45a7ac497c0355509ae52a965bbeb5840b8d))
* check template hygiene, blocking work, and suppression comments ([1e46387](https://github.com/leonqadirie/soundcheck/commit/1e46387fe24c101188d1d0759b0186fe9b68c027))
* extract LiveView hook facts from JavaScript sources ([f6c2c34](https://github.com/leonqadirie/soundcheck/commit/f6c2c34f063996014fadab0ae0307f879ed91668))
* read compiled modules and index modules from source ([378373c](https://github.com/leonqadirie/soundcheck/commit/378373c7cb118602943bca9eef54a05332abdbc5))

## Changelog

All notable changes to this project will be documented in this file.
