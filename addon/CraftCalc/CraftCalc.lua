-- CraftCalc - Profession profit calculator for Turtle WoW (1.12.1)
-- /cc to toggle

local AH_CUT = 0.95
local MAX_ROWS = 16
local ROW_H = 22
local FRAME_W = 540
local FRAME_H = 500
local TABS_PER_ROW = 5
local PAGE_OFFSET = 0

local VENDOR = {}
VENDOR[2320]=10  VENDOR[2321]=100  VENDOR[4291]=500  VENDOR[8343]=2000  VENDOR[14341]=5000
VENDOR[2324]=25  VENDOR[2604]=50   VENDOR[2605]=100  VENDOR[4340]=50    VENDOR[4341]=50
VENDOR[6260]=50  VENDOR[6261]=100  VENDOR[10290]=250
VENDOR[3371]=20  VENDOR[3372]=200  VENDOR[8925]=500  VENDOR[18256]=6000
VENDOR[2880]=100 VENDOR[3466]=2000 VENDOR[3857]=500
VENDOR[4399]=200 VENDOR[4470]=40   VENDOR[6217]=126
VENDOR[2678]=10  VENDOR[2692]=40   VENDOR[3713]=80   VENDOR[6530]=50
VENDOR[159]=25   VENDOR[1179]=125  VENDOR[17194]=100 VENDOR[17196]=200

CC = {}
CC.prices = {}
CC.factionKey = nil
CC.currentProf = nil
CC.enriched = {}
CC.tsIndex = {}
CC.tsOpen = false
CC.initialized = false

local recipeByResult = {}
local mainFrame, rowFrames, statusTxt, profTabs, pageLabel

-- Vanilla: plain Button has no default font string, so add one explicitly
local function BtnWithLabel(parent, name, w, h, text, font)
    local btn = CreateFrame("Button", name, parent)
    btn:SetWidth(w)
    btn:SetHeight(h)
    local fs = btn:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
    fs:SetPoint("CENTER", btn, "CENTER", 0, 0)
    fs:SetText(text)
    btn.label = fs
    return btn
end

local function SplitOnChar(str, ch)
    local t = {}
    local pos = 1
    while true do
        local s, e = string.find(str, ch, pos, true)
        if s then
            table.insert(t, string.sub(str, pos, s - 1))
            pos = e + 1
        else
            table.insert(t, string.sub(str, pos))
            break
        end
    end
    return t
end

local function CountItemInBags(itemId)
    local total = 0
    local bag, slot
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag)
        if slots and slots > 0 then
            for slot = 1, slots do
                local link = GetContainerItemLink(bag, slot)
                if link then
                    local _, _, idStr = string.find(link, "item:(%d+)")
                    if idStr and tonumber(idStr) == itemId then
                        local _, cnt = GetContainerItemInfo(bag, slot)
                        total = total + (cnt or 1)
                    end
                end
            end
        end
    end
    return total
end

local function ParseAuxEntry(str)
    local parts = SplitOnChar(str, "#")
    local p2 = parts[2]
    local p3 = parts[3]

    local minBuyout = nil
    if p2 and string.len(p2) > 0 then
        local v = tonumber(p2)
        if v and v > 0 then minBuyout = math.floor(v) end
    end

    local volume = 0
    local marketValue = minBuyout

    if p3 and string.len(p3) > 0 then
        local dps = {}
        local dp
        for dp in string.gfind(p3, "[^;]+") do
            local _, _, vs, ts = string.find(dp, "(.+)@(.+)")
            if vs and ts then
                table.insert(dps, { value = math.floor(tonumber(vs) or 0), t = tonumber(ts) or 0 })
            end
        end
        volume = table.getn(dps)
        if volume > 0 then
            local refTime = dps[1].t
            local totalW = 0
            local i
            for i = 1, volume do
                local days = math.floor((refTime - dps[i].t) / 86400)
                dps[i].w = 0.99 ^ days
                totalW = totalW + dps[i].w
            end
            if totalW > 0 then
                for i = 1, volume do dps[i].w = dps[i].w / totalW end
                table.sort(dps, function(a, b) return a.value < b.value end)
                local cum = 0
                for i = 1, volume do
                    cum = cum + dps[i].w
                    if cum >= 0.5 then
                        if not marketValue then marketValue = dps[i].value end
                        break
                    end
                end
            end
        end
    end
    return minBuyout, marketValue, volume
end

function CC:LoadPrices()
    self.prices = {}
    if not aux or not aux.faction then return 0 end
    local fdata = aux.faction[self.factionKey]
    if not fdata or not fdata.history then return 0 end
    local count = 0
    for key, data in pairs(fdata.history) do
        local _, _, idStr, sfxStr = string.find(key, "^(%d+):(%d+)")
        local itemId = tonumber(idStr)
        local suffix = tonumber(sfxStr)
        if itemId and suffix == 0 then
            local minBuyout, marketValue, vol = ParseAuxEntry(data)
            if marketValue then
                self.prices[itemId] = { minBuyout = minBuyout, marketValue = marketValue, volume = vol }
                count = count + 1
            end
        end
    end
    return count
end

function CC:GetEffectivePrice(itemId)
    local p = self.prices[itemId]
    local ah = nil
    if p then ah = p.marketValue or p.minBuyout end
    local vnd = VENDOR[itemId]
    if ah and vnd then
        if ah < vnd then return ah else return vnd end
    elseif ah then
        return ah
    elseif vnd then
        return vnd
    end
    return nil
end

function CC:GetSellPrice(itemId)
    local p = self.prices[itemId]
    if not p then return nil end
    local ah = p.marketValue or p.minBuyout
    if not ah then return nil end
    return math.floor(ah * AH_CUT)
end

function CC:CalcCraftCost(recipe, visited)
    if not visited then visited = {} end
    if visited[recipe.id] then return nil end
    visited[recipe.id] = true
    local total = 0
    local i
    for i = 1, table.getn(recipe.r) do
        local rr = recipe.r[i]
        local itemId = rr[1]
        local qty = rr[2]
        local sub = recipeByResult[itemId]
        local buy = self:GetEffectivePrice(itemId)
        if sub and not visited[sub.id] then
            local v2 = {}
            for k, vv in pairs(visited) do v2[k] = vv end
            local craft = self:CalcCraftCost(sub, v2)
            if buy and craft then
                if buy < craft then
                    total = total + buy * qty
                else
                    total = total + craft * qty
                end
            elseif craft then
                total = total + craft * qty
            elseif buy then
                total = total + buy * qty
            else
                return nil
            end
        else
            if buy then
                total = total + buy * qty
            else
                return nil
            end
        end
    end
    return total
end

function CC:GetCraftableCount(recipe)
    local mn = 99999
    local i
    for i = 1, table.getn(recipe.r) do
        local rr = recipe.r[i]
        local n = math.floor(CountItemInBags(rr[1]) / rr[2])
        if n < mn then mn = n end
    end
    if mn == 99999 then return 0 end
    return mn
end

local function FormatCopper(c)
    if not c then return "-" end
    local neg = (c < 0)
    if neg then c = -c end
    c = math.floor(c)
    local g = math.floor(c / 10000)
    local s = math.floor(mod(c, 10000) / 100)
    local co = mod(c, 100)
    local out = ""
    if neg then out = "-" end
    if g > 0 then out = out .. g .. "g " end
    out = out .. s .. "s " .. co .. "c"
    return out
end

local function VolStr(n)
    if not n or n == 0 then return "-" end
    if n < 5 then return "low" end
    if n < 20 then return "med" end
    return "high"
end

function CC:Recalculate()
    self.enriched = {}
    if not CC_RECIPES then return end
    local prof = CC_RECIPES[self.currentProf]
    if not prof then return end
    local i
    for i = 1, table.getn(prof.recipes) do
        local recipe = prof.recipes[i]
        local craftCost = self:CalcCraftCost(recipe)
        local sellPrice = nil
        if recipe.result then sellPrice = self:GetSellPrice(recipe.result) end
        local profit = nil
        if craftCost and sellPrice then profit = sellPrice - craftCost end
        local vol = 0
        if recipe.result and self.prices[recipe.result] then
            vol = self.prices[recipe.result].volume or 0
        end
        table.insert(self.enriched, {
            recipe = recipe,
            craftCost = craftCost,
            sellPrice = sellPrice,
            profit = profit,
            craftable = self:GetCraftableCount(recipe),
            vol = vol,
        })
    end
    table.sort(self.enriched, function(a, b)
        if a.profit and b.profit then return a.profit > b.profit end
        if a.profit then return true end
        return false
    end)
end

function CC:ScanTradeSkillWindow()
    self.tsIndex = {}
    if not self.tsOpen then return end
    if not CC_RECIPES or not CC_RECIPES[self.currentProf] then return end
    local n = GetNumTradeSkills()
    if not n then return end
    local i, j
    for i = 1, n do
        local sName, sType = GetTradeSkillInfo(i)
        if sName and sType ~= "header" then
            local recipes = CC_RECIPES[self.currentProf].recipes
            for j = 1, table.getn(recipes) do
                if recipes[j].name == sName and recipes[j].result then
                    self.tsIndex[recipes[j].result] = i
                end
            end
        end
    end
end

function CC:TryCraft(recipe, count)
    if not self.tsOpen then
        DEFAULT_CHAT_FRAME:AddMessage("CraftCalc: Open trade skill window first.")
        return
    end
    local idx = self.tsIndex[recipe.result]
    if not idx then
        self:ScanTradeSkillWindow()
        idx = self.tsIndex[recipe.result]
    end
    if idx then
        DoTradeSkill(idx, count or 1)
    else
        DEFAULT_CHAT_FRAME:AddMessage("CraftCalc: Recipe not in open trade skill window.")
    end
end

function CC:UpdateRows()
    if not rowFrames then return end
    local total = table.getn(self.enriched)
    if PAGE_OFFSET >= total and PAGE_OFFSET > 0 then PAGE_OFFSET = 0 end

    local i
    for i = 1, MAX_ROWS do
        local row = rowFrames[i]
        if row then
            local idx = i + PAGE_OFFSET
            if idx <= total then
                local e = self.enriched[idx]
                local profitStr = "?"
                if e.profit then
                    if e.profit >= 0 then
                        profitStr = "+" .. FormatCopper(e.profit)
                    else
                        profitStr = FormatCopper(e.profit)
                    end
                end
                row.nameTxt:SetText(e.recipe.name)
                row.volTxt:SetText(VolStr(e.vol))
                row.profitTxt:SetText(profitStr)
                if e.craftable > 0 then
                    row.canTxt:SetText("x" .. e.craftable)
                else
                    row.canTxt:SetText("x0")
                end
                row.craftBtn.entry = e
                row:Show()
            else
                row:Hide()
            end
        end
    end

    if pageLabel then
        local pages = math.max(1, math.ceil(total / MAX_ROWS))
        local cur = math.floor(PAGE_OFFSET / MAX_ROWS) + 1
        pageLabel:SetText("Page " .. cur .. "/" .. pages .. "  (" .. total .. " recipes)")
    end
end

function CC:UpdateProfTabs()
    if not profTabs then return end
    for key, btn in pairs(profTabs) do
        if btn.label then
            if key == self.currentProf then
                btn.label:SetFontObject(GameFontHighlight)
            else
                btn.label:SetFontObject(GameFontNormal)
            end
        end
    end
end

function CC:UpdateStatus(n)
    if not statusTxt then return end
    if self.factionKey then
        statusTxt:SetText(self.factionKey .. " - " .. (n or 0) .. " AH items")
    else
        statusTxt:SetText("No price data loaded.")
    end
end

function CC:Refresh()
    local n = self:LoadPrices()
    self:Recalculate()
    self:UpdateProfTabs()
    self:UpdateRows()
    self:UpdateStatus(n)
end

function CC:BuildUI()
    local f = CreateFrame("Frame", "CraftCalcFrame", UIParent)
    f:SetWidth(FRAME_W)
    f:SetHeight(FRAME_H)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0, 0, 0, 0.95)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() this:StartMoving() end)
    f:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    f:SetFrameStrata("HIGH")
    f:Hide()
    mainFrame = f

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -10)
    title:SetText("CraftCalc")

    local closeBtn = BtnWithLabel(f, "CraftCalcCloseBtn", 20, 20, "X", "GameFontNormal")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() mainFrame:Hide() end)

    local refreshBtn = BtnWithLabel(f, "CraftCalcRefreshBtn", 55, 18, "Refresh")
    refreshBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -32, -8)
    refreshBtn:SetScript("OnClick", function() CC:Refresh() end)

    statusTxt = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusTxt:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -30)
    statusTxt:SetTextColor(0.7, 0.7, 0.7)

    profTabs = {}
    if CC_RECIPES then
        local profKeys = {}
        for k in pairs(CC_RECIPES) do table.insert(profKeys, k) end
        table.sort(profKeys)
        local numProfs = table.getn(profKeys)
        local tabW = math.floor((FRAME_W - 20) / TABS_PER_ROW)
        local ii
        for ii = 1, numProfs do
            local key = profKeys[ii]
            local col = mod(ii - 1, TABS_PER_ROW)
            local row = math.floor((ii - 1) / TABS_PER_ROW)
            local btn = BtnWithLabel(f, "CraftCalcTab" .. ii, tabW - 4, 16, CC_RECIPES[key].name, "GameFontNormalSmall")
            btn:SetPoint("TOPLEFT", f, "TOPLEFT", 10 + col * tabW, -50 - row * 18)
            btn.profKey = key
            btn:SetScript("OnClick", function()
                CC.currentProf = this.profKey
                PAGE_OFFSET = 0
                CC:Recalculate()
                CC:UpdateProfTabs()
                CC:UpdateRows()
            end)
            profTabs[key] = btn
        end
    end

    -- Column headers (below 2 rows of prof tabs)
    local hdrY = -92
    local h1 = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h1:SetPoint("TOPLEFT", f, "TOPLEFT", 10, hdrY)
    h1:SetText("Recipe")
    h1:SetTextColor(0.5, 0.5, 0.6)
    local h2 = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h2:SetPoint("TOPLEFT", f, "TOPLEFT", 330, hdrY)
    h2:SetText("Vol")
    h2:SetTextColor(0.5, 0.5, 0.6)
    local h3 = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h3:SetPoint("TOPLEFT", f, "TOPLEFT", 385, hdrY)
    h3:SetText("Profit")
    h3:SetTextColor(0.5, 0.5, 0.6)
    local h4 = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h4:SetPoint("TOPRIGHT", f, "TOPRIGHT", -52, hdrY)
    h4:SetText("Can")
    h4:SetTextColor(0.5, 0.5, 0.6)

    local sep = f:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", f, "TOPLEFT", 8, hdrY - 12)
    sep:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, hdrY - 12)
    sep:SetTexture(0.3, 0.3, 0.4, 0.8)

    local listTop = hdrY - 18
    rowFrames = {}
    for i = 1, MAX_ROWS do
        local row = CreateFrame("Button", "CraftCalcRow" .. i, f)
        row:SetHeight(ROW_H)
        row:SetWidth(FRAME_W - 20)
        row:SetPoint("TOPLEFT", f, "TOPLEFT", 10, listTop - (i - 1) * ROW_H)

        row.rowIdx = i
        row:SetScript("OnEnter", function()
            local idx = this.rowIdx + PAGE_OFFSET
            local e = CC.enriched[idx]
            if not e then return end
            GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
            GameTooltip:ClearLines()
            GameTooltip:AddLine(e.recipe.name, 1, 1, 1)
            GameTooltip:AddLine(" ")
            local j
            for j = 1, table.getn(e.recipe.r) do
                local rr = e.recipe.r[j]
                local nm = "Item#" .. rr[1]
                if CC_ITEMS and CC_ITEMS[rr[1]] then nm = CC_ITEMS[rr[1]] end
                local have = CountItemInBags(rr[1])
                GameTooltip:AddDoubleLine(rr[2] .. "x " .. nm, have .. " in bags")
            end
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine("Craft cost", FormatCopper(e.craftCost))
            GameTooltip:AddDoubleLine("Sell -5%", FormatCopper(e.sellPrice))
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)

        local nameTxt = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        nameTxt:SetPoint("LEFT", row, "LEFT", 0, 0)
        nameTxt:SetWidth(310)
        nameTxt:SetJustifyH("LEFT")
        row.nameTxt = nameTxt

        local volTxt = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        volTxt:SetPoint("LEFT", row, "LEFT", 322, 0)
        volTxt:SetWidth(55)
        row.volTxt = volTxt

        local profitTxt = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        profitTxt:SetPoint("LEFT", row, "LEFT", 378, 0)
        profitTxt:SetWidth(72)
        row.profitTxt = profitTxt

        local canTxt = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        canTxt:SetPoint("RIGHT", row, "RIGHT", -48, 0)
        canTxt:SetWidth(28)
        canTxt:SetJustifyH("RIGHT")
        row.canTxt = canTxt

        local craftBtn = BtnWithLabel(row, "CraftCalcCraft" .. i, 42, 16, "Craft")
        craftBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        craftBtn:SetScript("OnClick", function()
            local e = this.entry
            if not e then return end
            local cnt = e.craftable or 0
            if cnt < 1 then cnt = 1 end
            CC:TryCraft(e.recipe, cnt)
        end)
        row.craftBtn = craftBtn

        row:Hide()
        rowFrames[i] = row
    end

    local prevBtn = BtnWithLabel(f, "CraftCalcPrevBtn", 50, 18, "< Prev")
    prevBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 8)
    prevBtn:SetScript("OnClick", function()
        if PAGE_OFFSET >= MAX_ROWS then
            PAGE_OFFSET = PAGE_OFFSET - MAX_ROWS
            CC:UpdateRows()
        end
    end)

    pageLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pageLabel:SetPoint("BOTTOM", f, "BOTTOM", 0, 12)
    pageLabel:SetTextColor(0.6, 0.6, 0.6)

    local nextBtn = BtnWithLabel(f, "CraftCalcNextBtn", 50, 18, "Next >")
    nextBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 8)
    nextBtn:SetScript("OnClick", function()
        local total = table.getn(CC.enriched)
        if PAGE_OFFSET + MAX_ROWS < total then
            PAGE_OFFSET = PAGE_OFFSET + MAX_ROWS
            CC:UpdateRows()
        end
    end)
end

function CC:Toggle()
    if not mainFrame then
        DEFAULT_CHAT_FRAME:AddMessage("CraftCalc: not initialized yet.")
        return
    end
    if mainFrame:IsShown() then
        mainFrame:Hide()
    else
        mainFrame:Show()
        self:Refresh()
    end
end

function CC:Init()
    if self.initialized then return end
    self.initialized = true

    local faction = UnitFactionGroup("player")
    local realm = GetRealmName()
    if realm and faction then
        self.factionKey = realm .. "|" .. faction
    end

    if CC_RECIPES then
        local profKeys = {}
        for k in pairs(CC_RECIPES) do table.insert(profKeys, k) end
        table.sort(profKeys)
        local ii, jj
        for ii = 1, table.getn(profKeys) do
            local prof = CC_RECIPES[profKeys[ii]]
            for jj = 1, table.getn(prof.recipes) do
                local r = prof.recipes[jj]
                if r.result then recipeByResult[r.result] = r end
            end
        end
        if table.getn(profKeys) > 0 then
            self.currentProf = profKeys[1]
        end
    end

    self:BuildUI()
    DEFAULT_CHAT_FRAME:AddMessage("CraftCalc loaded. Type /cc to open.")
end

local ef = CreateFrame("Frame", "CraftCalcEvents")
ef:RegisterEvent("VARIABLES_LOADED")
ef:RegisterEvent("TRADE_SKILL_SHOW")
ef:RegisterEvent("TRADE_SKILL_CLOSE")
ef:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" then
        CC:Init()
    elseif event == "TRADE_SKILL_SHOW" then
        CC.tsOpen = true
        CC:ScanTradeSkillWindow()
        local tsName = GetTradeSkillLine()
        if tsName and CC_RECIPES and CC_RECIPES[tsName] then
            CC.currentProf = tsName
            PAGE_OFFSET = 0
            if mainFrame and mainFrame:IsShown() then
                CC:Recalculate()
                CC:UpdateProfTabs()
                CC:UpdateRows()
            end
        end
    elseif event == "TRADE_SKILL_CLOSE" then
        CC.tsOpen = false
        CC.tsIndex = {}
    end
end)

SLASH_CRAFTCALC1 = "/cc"
SLASH_CRAFTCALC2 = "/craftcalc"
SlashCmdList["CRAFTCALC"] = function()
    if not CC.initialized then CC:Init() end
    CC:Toggle()
end
