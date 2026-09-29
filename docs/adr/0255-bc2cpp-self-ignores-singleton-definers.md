# 255. A `self` call in an instance method ignores `.singleton` definers

Date: 2026-09-29

## Status

Accepted

## Context

`ClosedWorld#required_classes(name)` refuses (`:singleton_definer`) as soon as any
definition of the name lives on a `.singleton` owner (`def self.x`, `class << self`).
Such a method belongs to a class or module object, so the refusal is right for a
receiver that might be one. It also blocked every call of the name on a receiver
that provably is not: `term` is defined on `Game::Party`, `RPG2k::Scene::Base` and
`Game::States::BattleText.singleton`, and that last definition kept the dispatch
in 87 `term(...)` self-calls of `RPG2k::Scene::*` methods.

## Decision

`required_classes` takes `instance_self`. When the receiver is `self` inside an
instance method of a declared class (`ClosedWorld#instance_self?`) the
`.singleton` definitions are skipped. `self` there is an instance of the class or
a descendant, never a class or module object, so no singleton method can answer.
`instance_self?` is false for a module (its `self` may be the module or an
includer), for an undeclared class, and for a class whose superclass chain reaches
`Module`/`Class` or is unresolved (its instances would be class objects).
`refusal` and `unlisted_classes` derive the flag from the site's `self_owner`.
A singleton installed onto one instance (`def obj.x`, `extend`) is not a
`.singleton` definition; it is already a refusal through the unknown-definer and
dynamic-install checks.

## Consequences

- 74 `self.term` sends (31 reviewed keys) become proven-dead `bc2cpp_nomethod`
  terminals; `singleton_definer` kept sites go from 92 to 18 (non-self receivers).
- All 31 new `NOMETHOD_REVIEWED` keys are bare `term(...)` calls in
  `RPG2k::Scene::*` methods (read against the source): the receiver is always a
  Scene instance and `Scene::Base#term` answers it.
- Hot-only builds stay consistent with the full list (`bc2cpp_nomethod_reviewed_check`).
