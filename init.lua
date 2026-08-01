--- Stacked Editions
--- Lets a card carry several editions at once.
---
--- Data model: `card.edition` stays a single flat table (so every vanilla/mod
--- check like `card.edition.negative` or `card.edition.x_mult` keeps working),
--- but it also holds `card.edition.editions` = ordered list of applied edition
--- keys. That list is the source of truth and is saved with the card for free.

local mod = SMODS.current_mod
local function config()
    mod.config = mod.config or {}
    return mod.config
end

StackedEditions = {}
local SE = StackedEditions

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------

--- localize() with a fallback, so a missing translation never prints ERROR
function SE.L(key, fallback)
    local s = localize(key)
    if type(s) ~= 'string' or s == 'ERROR' then return fallback end
    return s
end

-- ordered list of edition keys held by an edition table
function SE.stack_of(ed)
    if type(ed) ~= 'table' then return {} end
    if ed.editions then return ed.editions end
    -- set by unpatched code / old save: single edition
    if ed.key then return { ed.key } end
    for k, v in pairs(ed) do
        if v == true and G.P_CENTERS['e_' .. k] then return { 'e_' .. k } end
    end
    return {}
end

-- ordered list of edition keys applied to a card
function SE.stack(card)
    return SE.stack_of(card.edition)
end

-- stack with duplicates removed, order preserved
function SE.unique_stack(ed)
    local seen, out = {}, {}
    for _, key in ipairs(SE.stack_of(ed)) do
        if not seen[key] then
            seen[key] = true
            out[#out + 1] = key
        end
    end
    return out
end

--- Can this card take one more edition at all (max_editions)?
--- Used by target pools so a consumable is never offered a card it cannot change.
function SE.can_take_more(card)
    local limit = config().max_editions or 0
    if limit <= 0 then return true end
    return #SE.stack(card) < limit
end

--- Can this specific edition still be applied to the card?
function SE.can_apply(card, key)
    if not SE.can_take_more(card) then return false end
    if config().allow_duplicates then return true end
    return not SE.has(SE.stack(card), key)
end

function SE.has(stack, key)
    for _, k in ipairs(stack) do
        if k == key then return true end
    end
    return false
end

-- accept every form vanilla/mods pass to set_edition
function SE.keys_of(edition)
    if type(edition) == 'string' then
        return { edition:sub(1, 2) == 'e_' and edition or ('e_' .. edition) }
    end
    if type(edition) ~= 'table' then return {} end
    if edition.editions then
        local out = {}
        for _, k in ipairs(edition.editions) do out[#out + 1] = k end
        return out
    end
    if edition.type then return { 'e_' .. edition.type } end
    if edition.key then return { edition.key } end
    local out = {}
    for k, v in pairs(edition) do
        if v and G.P_CENTERS['e_' .. tostring(k)] then out[#out + 1] = 'e_' .. k end
    end
    return out
end

local function is_multiplicative(k)
    return k:sub(1, 2) == 'x_' or k:sub(1, 2) == 'X' or k == 'xmult' or k == 'xchips'
end

-- how two editions' values for the same config key combine
local function combine(k, a, b)
    if a == nil then return b end
    if b == nil then return a end
    if type(a) == 'number' and type(b) == 'number' then
        if is_multiplicative(k) then return a * b end
        return a + b
    end
    if type(a) == 'boolean' and type(b) == 'boolean' then return a or b end
    return b -- strings/tables: last edition wins
end

local reserved = { editions = true, type = true, key = true }

-- rebuild card.edition from a list of edition keys
function SE.rebuild(card, stack)
    if card.edition then
        card.ability.card_limit = card.ability.card_limit - (card.edition.card_limit or 0)
        card.ability.extra_slots_used = card.ability.extra_slots_used - (card.edition.extra_slots_used or 0)
        for _, key in ipairs(SE.stack(card)) do
            card.ignore_base_shader[key] = nil
            card.ignore_shadow[key] = nil
        end
    end

    if #stack == 0 then
        card.edition = nil
        card:set_cost()
        return
    end

    local ed = { editions = stack }
    for _, key in ipairs(stack) do
        local center = G.P_CENTERS[key]
        if center then
            local name = key:sub(3)
            ed[name] = true
            -- primary edition = last applied, used by code expecting one edition
            ed.type = name
            ed.key = key
            if center.override_base_shader or center.disable_base_shader then
                card.ignore_base_shader[key] = true
            end
            if center.no_shadow or center.disable_shadow then
                card.ignore_shadow[key] = true
            end
            for k, v in pairs(center.config or {}) do
                if not reserved[k] then
                    ed[k] = combine(k, ed[k], type(v) == 'table' and copy_table(v) or v)
                end
            end
        end
    end

    card.edition = ed
    card.ability.card_limit = card.ability.card_limit + (ed.card_limit or 0)
    card.ability.extra_slots_used = card.ability.extra_slots_used + (ed.extra_slots_used or 0)
    card:set_cost()
end

--------------------------------------------------------------------------------
-- Card:set_edition -- additive instead of replacing
--------------------------------------------------------------------------------

local set_edition_ref = Card.set_edition

function Card:set_edition(edition, immediate, silent, delay)
    if SE.bypass then return set_edition_ref(self, edition, immediate, silent, delay) end
    silent = silent or SMODS.create_card_silent_edition

    local new_keys = SE.keys_of(edition)
    local old_edition = self.edition

    -- no edition / base = strip everything (copy_card strip_edition, etc.)
    if #new_keys == 0 or new_keys[1] == 'e_base' then
        if not self.edition then return end
        for _, key in ipairs(SE.stack(self)) do
            local center = G.P_CENTERS[key]
            if center and type(center.on_remove) == 'function' then center.on_remove(self) end
        end
        SMODS.enh_cache:write(self, nil)
        SE.rebuild(self, {})
        if not silent then
            G.E_MANAGER:add_event(Event({
                trigger = 'after',
                delay = not immediate and 0.2 or 0,
                blockable = not immediate,
                func = function()
                    self:juice_up(1, 0.5)
                    play_sound('whoosh2', 1.2, 0.6)
                    return true
                end
            }))
        end
        if delay then
            self.delay_edition = old_edition
            G.E_MANAGER:add_event(Event({ trigger = 'immediate', func = function()
                self.delay_edition = nil; return true
            end }))
        end
        return
    end

    local stack = {}
    for _, k in ipairs(SE.stack(self)) do stack[#stack + 1] = k end

    local added = {}
    for _, key in ipairs(new_keys) do
        local limit = config().max_editions or 0
        local dupe = SE.has(stack, key) and not config().allow_duplicates
        if G.P_CENTERS[key] and not dupe and (limit <= 0 or #stack < limit) then
            stack[#stack + 1] = key
            added[#added + 1] = key
        end
    end
    if #added == 0 then return end

    SMODS.enh_cache:write(self, nil)
    SE.rebuild(self, stack)

    for _, key in ipairs(added) do
        local center = G.P_CENTERS[key]
        if type(center.on_apply) == 'function' then center.on_apply(self) end
        if self.area and self.area == G.jokers and not center.discovered then
            discover_card(center)
        end
    end

    if not silent then
        local center = G.P_CENTERS[added[#added]]
        local sound = center.sound or { sound = 'foil1', per = 1.2, vol = 0.4 }
        G.CONTROLLER.locks.edition = true
        G.E_MANAGER:add_event(Event({
            trigger = 'after',
            delay = not immediate and 0.2 or 0,
            blockable = not immediate,
            func = function()
                if self.edition then
                    self:juice_up(1, 0.5)
                    play_sound(sound.sound, sound.per, sound.vol)
                end
                return true
            end
        }))
        G.E_MANAGER:add_event(Event({ trigger = 'after', delay = 0.1, func = function()
            G.CONTROLLER.locks.edition = false; return true
        end }))
    end

    if delay then
        self.delay_edition = old_edition or { base = true }
        G.E_MANAGER:add_event(Event({ trigger = 'immediate', func = function()
            self.delay_edition = nil; return true
        end }))
    end
end

--- Remove a single edition from a card.
function SE.remove(card, key)
    local stack, out, found = SE.stack(card), {}, false
    for _, k in ipairs(stack) do
        if k == key and not found then
            found = true
            local center = G.P_CENTERS[k]
            if center and type(center.on_remove) == 'function' then center.on_remove(card) end
        else
            out[#out + 1] = k
        end
    end
    if not found then return false end
    SMODS.enh_cache:write(card, nil)
    SE.rebuild(card, out)
    return true
end

--------------------------------------------------------------------------------
-- scoring: run every edition's calculate, merge results into one effect table
--------------------------------------------------------------------------------

local function merge_effects(a, b)
    for k, v in pairs(b) do
        if k == 'func' and type(a.func) == 'function' and type(v) == 'function' then
            local first, second = a.func, v
            a.func = function(...) first(...); return second(...) end
        elseif a[k] == nil then
            a[k] = v
        elseif type(a[k]) == 'number' and type(v) == 'number' then
            a[k] = combine(k, a[k], v)
        end
        -- otherwise keep the earlier edition's value (messages, cards, ...)
    end
    return a
end

function Card:calculate_edition(context)
    local out
    for _, key in ipairs(SE.stack(self)) do
        local center = G.P_CENTERS[key]
        if center and type(center.calculate) == 'function' then
            local o = center:calculate(self, context)
            if o then
                o.card = o.card or self
                out = out and merge_effects(out, o) or o
            end
        end
    end
    return out
end

--------------------------------------------------------------------------------
-- info box: one badge per applied edition
--------------------------------------------------------------------------------

-- SMODS uses card.edition.key to pick the card_limit badge; with a stack the
-- primary edition may not be the one providing card_limit (e.g. Negative +
-- Polychrome, primary = Polychrome, which has no card_limit_keys).
function SMODS.Edition.get_card_limit_key(card)
    for _, key in ipairs(SE.stack(card)) do
        local center = G.P_CENTERS[key]
        if center and center.card_limit_keys then return center:card_limit_key(card) end
    end
    return (card.edition and card.edition.type) or 'negative'
end

--- How many times the edition behind a badge label key sits in the stack.
--- Label keys can be plain ('polychrome'), aliased ('holographic') or SMODS
--- card_limit keys with the area appended ('negative_playing_card').
function SE.badge_count(card, label_key)
    if type(card) ~= 'table' or not card.edition or type(label_key) ~= 'string' then return nil end
    local name = label_key == 'holographic' and 'holo' or label_key
    local exact, prefixed = 0, 0
    for _, key in ipairs(SE.stack(card)) do
        local ed = key:sub(3)
        if name == ed then
            exact = exact + 1
        elseif name:sub(1, #ed + 1) == ed .. '_' then
            prefixed = prefixed + 1
        end
    end
    return exact > 0 and exact or prefixed
end

local function badge_name(card, key)
    local center = G.P_CENTERS[key]
    local name = key:sub(3)
    if center and center.card_limit_keys then return center:card_limit_key(card) end
    return name == 'holo' and 'holographic' or name
end

local generate_card_ui_ref = generate_card_ui
function generate_card_ui(_c, full_UI_table, specific_vars, card_type, badges, hide_desc, main_start, main_end, card)
    local stack = card and SE.stack(card) or {}
    if badges and #stack > 1 then
        local want = {}
        for _, key in ipairs(stack) do
            want[#want + 1] = badge_name(card, key)
        end
        local at = 1
        for i, b in ipairs(badges) do
            for _, name in ipairs(want) do
                if b == name then at = i end
            end
        end
        for _, name in ipairs(want) do
            local present = false
            for _, b in ipairs(badges) do
                if b == name then present = true end
            end
            if not present then
                at = at + 1
                table.insert(badges, at, name)
            end
        end
    end
    return generate_card_ui_ref(_c, full_UI_table, specific_vars, card_type, badges, hide_desc, main_start, main_end, card)
end

--------------------------------------------------------------------------------
-- rendering: blend every edition shader onto the card
--------------------------------------------------------------------------------

-- SMODS' 'edition' draw step already draws one pass per edition flag, but each
-- pass repaints the whole sprite opaquely, so only the last one is visible.
-- Draw pass k at alpha 1/k instead: every edition ends up with an equal 1/n
-- share of the card. G.BRUTE_OVERLAY is the colour Sprite:draw_self/draw_from
-- fall back to (engine/sprite.lua:133), and nothing else in the game sets it.
local edition_step = SMODS.DrawSteps and SMODS.DrawSteps.edition
if not edition_step and SMODS.DrawSteps then
    for k, v in pairs(SMODS.DrawSteps) do
        if type(k) == 'string' and k:match('edition$') then edition_step = v end
    end
end
if edition_step then
    edition_step.func = function(self, layer)
        local edition = self.delay_edition or self.edition
        local stack = SE.unique_stack(edition)
        local prev_overlay = G.BRUTE_OVERLAY
        local pass = 0
        local blend = config().blend_overlays ~= false

        -- editions that replace the base shader (Negative) paint the backdrop,
        -- so draw them first and let the shiny ones blend on top
        table.sort(stack, function(a, b)
            local ca, cb = G.P_CENTERS[a] or {}, G.P_CENTERS[b] or {}
            local base_a = (ca.override_base_shader or ca.disable_base_shader) and 1 or 0
            local base_b = (cb.override_base_shader or cb.disable_base_shader) and 1 or 0
            if base_a ~= base_b then return base_a > base_b end
            return false
        end)

        for _, key in ipairs(stack) do
            local center = G.P_CENTERS[key]
            if center and center.shader then
                pass = pass + 1
                G.BRUTE_OVERLAY = (blend and pass > 1) and { 1, 1, 1, 1 / pass } or nil
                if type(center.draw) == 'function' then
                    center:draw(self, layer)
                else
                    self.children.center:draw_shader(center.shader, nil, self.ARGS.send_to_shader)
                    if self.children.front and not self:should_hide_front() then
                        self.children.front:draw_shader(center.shader, nil, self.ARGS.send_to_shader)
                    end
                end
            end
        end

        G.BRUTE_OVERLAY = prev_overlay

        if (edition and edition.negative) or
            (self.ability.name == 'Antimatter' and (self.config.center.discovered or self.bypass_discovery_center)) then
            self.children.center:draw_shader('negative_shine', nil, self.ARGS.send_to_shader)
        end
    end
end

--------------------------------------------------------------------------------
-- loading a save: restore per-edition state
--------------------------------------------------------------------------------

local card_load_ref = Card.load
function Card:load(cardTable, other_card)
    local ret = card_load_ref(self, cardTable, other_card)
    local stack = SE.stack(self)
    if #stack > 1 then
        for _, key in ipairs(stack) do
            local center = G.P_CENTERS[key]
            if center then
                if center.override_base_shader or center.disable_base_shader then
                    self.ignore_base_shader[key] = true
                end
                if center.no_shadow or center.disable_shadow then
                    self.ignore_shadow[key] = true
                end
                -- SMODS already ran on_load for the primary edition
                if key ~= self.edition.key and type(center.on_load) == 'function' then
                    center.on_load(self)
                end
            end
        end
    end
    return ret
end

--------------------------------------------------------------------------------
-- third-party compatibility
--------------------------------------------------------------------------------

local unpack = table.unpack or unpack

--- Run `fn` with `card.edition` temporarily hidden on every joker that does not
--- already hold `skip_key`.
---
--- Plenty of mods pick edition targets with `not card.edition`, which finds
--- nothing once cards carry stacked editions. Those mods queue the actual
--- `set_edition` call in an event, so it runs after the editions are restored
--- here and stacks normally.
---
--- Use this to adapt another mod:
---     local ref = SomeMod.pick_target
---     SomeMod.pick_target = function(...)
---         local args = { ... }
---         return StackedEditions.with_editions_hidden(
---             function() return ref(unpack(args)) end, 'e_negative')
---     end
function SE.with_editions_hidden(fn, skip_key)
    local hidden = {}
    for _, card in ipairs((G.jokers or {}).cards or {}) do
        if card.edition and not (skip_key and SE.has(SE.stack(card), skip_key)) then
            hidden[#hidden + 1] = { card = card, edition = card.edition }
            card.edition = nil
        end
    end

    local ok, ret = pcall(fn)

    for _, h in ipairs(hidden) do h.card.edition = h.edition end
    if not ok then error(ret) end
    return ret
end

-- Black Seal (id black_seal): its target pool skips any joker that already has
-- an edition, so the seal silently does nothing once editions are stacked.
if BSM and BSM.utils and type(BSM.utils.add_negative_random_joker) == 'function' then
    local add_negative_ref = BSM.utils.add_negative_random_joker
    BSM.utils.add_negative_random_joker = function(...)
        local args = { ... }
        return SE.with_editions_hidden(function() return add_negative_ref(unpack(args)) end, 'e_negative')
    end
end

--------------------------------------------------------------------------------
-- config UI
--------------------------------------------------------------------------------

mod.config_tab = function()
    return {
        n = G.UIT.ROOT,
        config = { align = 'cm', padding = 0.05, colour = G.C.CLEAR },
        nodes = {
            create_toggle({
                label = SE.L('stked_allow_duplicates', 'Allow duplicate editions'),
                ref_table = config(),
                ref_value = 'allow_duplicates',
            }),
            create_toggle({
                label = SE.L('stked_blend_overlays', 'Blend edition overlays'),
                ref_table = config(),
                ref_value = 'blend_overlays',
            }),
            create_option_cycle({
                label = SE.L('stked_max_editions', 'Max editions per card'),
                scale = 0.8,
                options = { SE.L('stked_unlimited', 'unlimited'), 2, 3, 4, 5 },
                current_option = (config().max_editions or 0) == 0 and 1 or config().max_editions,
                opt_callback = 'stked_max_editions',
            }),
        }
    }
end

G.FUNCS.stked_max_editions = function(e)
    config().max_editions = e.to_key == 1 and 0 or (e.to_val or 0)
end
