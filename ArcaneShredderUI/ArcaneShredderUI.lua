local Addon = CreateFrame("Frame")
local L = ArcaneShredderL

local PREFIX = "AzerothCore"
local PROTOCOL_VERSION = 1
local REQUEST_TIMEOUT = 5
local ROW_COUNT = 7
local ROW_HEIGHT = 38

local pending = {}
local nextRequestId = 0
local connected = false
local helloScheduledAt = nil
local activeToken = nil
local previewItems = {}
local buildingPreview = nil
local previewExpiresAt = nil
local lastExpirySecond = nil
local emptyState = "start"
local lastItemRefresh = 0

local window
local statusFrame
local statusText
local summaryText
local expiryText
local previewButton
local confirmButton
local cancelButton
local scrollFrame
local rows = {}
local controls = {}
local FiltersValid

local function SetStatus(text, state)
    statusText:SetText(text)
    if state == true or state == "error" then
        statusText:SetTextColor(1, 0.35, 0.35)
        statusFrame:SetBackdropColor(0.24, 0.03, 0.03, 0.92)
    elseif state == "warning" then
        statusText:SetTextColor(1, 0.82, 0.32)
        statusFrame:SetBackdropColor(0.20, 0.12, 0.02, 0.92)
    elseif state == "success" then
        statusText:SetTextColor(0.55, 1, 0.55)
        statusFrame:SetBackdropColor(0.03, 0.18, 0.06, 0.92)
    else
        statusText:SetTextColor(0.85, 0.85, 0.85)
        statusFrame:SetBackdropColor(0.04, 0.08, 0.14, 0.92)
    end
end

local function HasPendingRequest()
    return next(pending) ~= nil
end

local function SetFiltersEnabled(enabled)
    if not controls.uncommon then
        return
    end

    local names = {
        "uncommon", "rare", "epic", "unbound", "soulbound", "backpack",
        "bag1", "bag2", "bag3", "bag4", "maxItemLevel", "defaults",
    }
    for _, name in ipairs(names) do
        if enabled then
            controls[name]:Enable()
        else
            controls[name]:Disable()
        end
    end
end

local function UpdateButtons()
    local busy = HasPendingRequest()
    local filtersAreValid = not controls.uncommon or FiltersValid()
    if connected and filtersAreValid and not activeToken and not busy then
        previewButton:Enable()
    else
        previewButton:Disable()
    end

    if connected and activeToken and #previewItems > 0 and not busy then
        confirmButton:Enable()
    else
        confirmButton:Disable()
    end

    if connected and activeToken and not busy then
        cancelButton:Enable()
    else
        cancelButton:Disable()
    end

    if activeToken and #previewItems > 0 then
        confirmButton:SetText(string.format(L.CONFIRM_COUNT, #previewItems))
    else
        confirmButton:SetText(L.CONFIRM)
    end
    SetFiltersEnabled(not activeToken and not buildingPreview and not busy)
end

local function Split(value)
    local fields = {}
    local start = 1
    while true do
        local position = string.find(value, ":", start, true)
        if not position then
            table.insert(fields, string.sub(value, start))
            break
        end
        table.insert(fields, string.sub(value, start, position - 1))
        start = position + 1
    end
    return fields
end

local function NextRequestId()
    nextRequestId = (nextRequestId + 1) % 65536
    return string.format("%04X", nextRequestId)
end

local function SendRequest(command, kind)
    local requestId = NextRequestId()
    local payload = "i" .. requestId .. command
    if string.len(PREFIX) + 1 + string.len(payload) > 255 then
        SetStatus(string.format(L.STATUS_ERROR, L.ERRORS.REQUEST_TOO_LARGE or "REQUEST_TOO_LARGE"), "error")
        return nil
    end

    pending[requestId] = {
        kind = kind,
        deadline = GetTime() + (kind == "confirm" and 30 or REQUEST_TIMEOUT),
    }
    SendAddonMessage(PREFIX, payload, "WHISPER", UnitName("player"))
    UpdateButtons()
    return requestId
end

local function ClearPreview()
    activeToken = nil
    previewItems = {}
    buildingPreview = nil
    previewExpiresAt = nil
    lastExpirySecond = nil
end

local function LocationText(item)
    if item.bag == 255 then
        return string.format(L.BACKPACK_LOCATION, item.slot)
    end
    return string.format(L.LOCATION, item.bag - 18, item.slot + 1)
end

local function FindPreviewItem(guid)
    for index, item in ipairs(previewItems) do
        if item.guid == guid then
            return index, item
        end
    end
    return nil, nil
end

local function HasFlag(flags, flag)
    return math.mod(flags or 0, flag * 2) >= flag
end

local function ItemDetails(item, itemLevel)
    local tags = {}
    if HasFlag(item.flags, 1) then table.insert(tags, L.TAG_SOULBOUND) end
    if HasFlag(item.flags, 2) then table.insert(tags, L.TAG_REFUNDABLE) end
    if HasFlag(item.flags, 4) then table.insert(tags, L.TAG_TRADEABLE) end
    if HasFlag(item.flags, 8) then table.insert(tags, L.TAG_ENCHANTED) end
    if HasFlag(item.flags, 16) then table.insert(tags, L.TAG_SOCKETED) end

    local details = string.format("iLvl %d — %s", itemLevel or item.itemLevel, LocationText(item))
    if #tags > 0 then
        details = details .. " — " .. table.concat(tags, ", ")
    end
    return details
end

local function EmptyStateText()
    if emptyState == "loading" then return L.EMPTY_LOADING end
    if emptyState == "empty" then return L.EMPTY_NO_RESULTS end
    if emptyState == "excluded" then return L.EMPTY_ALL_EXCLUDED end
    if emptyState == "cancelled" then return L.EMPTY_CANCELLED end
    if emptyState == "completed" then return L.EMPTY_COMPLETED end
    if emptyState == "expired" then return L.EMPTY_EXPIRED end
    return L.EMPTY_START
end

local function UpdateSummary()
    if activeToken then
        summaryText:SetText(string.format(L.SUMMARY_COUNT, #previewItems))
        local seconds = math.max(0, math.ceil((previewExpiresAt or GetTime()) - GetTime()))
        expiryText:SetText(string.format(L.EXPIRES_IN, seconds))
    else
        summaryText:SetText(L.SUMMARY_IDLE)
        expiryText:SetText("")
    end
end

local function RebuildRows()
    if not window then
        return
    end

    local offset = FauxScrollFrame_GetOffset(scrollFrame)
    local needsItemRefresh = false
    for rowIndex = 1, ROW_COUNT do
        local row = rows[rowIndex]
        local item = previewItems[offset + rowIndex]
        if item then
            local name, link, quality, itemLevel, _, _, _, _, _, texture = GetItemInfo(item.entry)
            row.item = item
            row.link = link
            row.icon:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")
            if name then
                local color = ITEM_QUALITY_COLORS[quality or item.quality]
                row.name:SetText(link or name)
                if color then
                    row.name:SetTextColor(color.r, color.g, color.b)
                else
                    row.name:SetTextColor(1, 1, 1)
                end
            else
                row.name:SetText(string.format(L.LOADING_ITEM, item.entry))
                row.name:SetTextColor(0.7, 0.7, 0.7)
                needsItemRefresh = true
            end
            row.details:SetText(ItemDetails(item, itemLevel))
            row:Show()
        else
            row.item = nil
            row.link = nil
            row:Hide()
        end
    end

    FauxScrollFrame_Update(scrollFrame, #previewItems, ROW_COUNT, ROW_HEIGHT)
    window.needsItemRefresh = needsItemRefresh
    if #previewItems == 0 then
        window.emptyText:SetText(EmptyStateText())
        window.emptyText:Show()
    else
        window.emptyText:Hide()
    end
    UpdateSummary()
    UpdateButtons()
end

local function CommitBuildingPreview()
    if not buildingPreview or not buildingPreview.ended or #buildingPreview.items ~= buildingPreview.expected then
        ClearPreview()
        emptyState = "start"
        SetStatus(L.STATUS_INCOMPLETE, "error")
        RebuildRows()
        return
    end

    local preview = buildingPreview
    activeToken = buildingPreview.token
    previewItems = buildingPreview.items
    previewExpiresAt = buildingPreview.expiresAt
    buildingPreview = nil
    emptyState = #previewItems > 0 and "preview" or "empty"
    if preview.truncatedTotal then
        SetStatus(string.format(L.STATUS_TRUNCATED, #previewItems, preview.truncatedTotal), "warning")
    else
        SetStatus(string.format(L.STATUS_PREVIEW, #previewItems), "success")
    end
    RebuildRows()
end

local function LocalizeError(code)
    return L.ERRORS[code] or code
end

local function ShowReadyStatus()
    local valid, message = FiltersValid()
    if valid then
        SetStatus(L.STATUS_READY, "success")
    else
        SetStatus(message, "error")
    end
end

local function ParseRecord(body)
    local fields = Split(body)
    if fields[1] ~= "ASHRED" then
        return
    end

    local record = fields[2]
    if record == "HELLO" then
        local serverProtocol = tonumber(fields[3])
        connected = serverProtocol == PROTOCOL_VERSION
        if connected then
            ShowReadyStatus()
        else
            SetStatus(string.format(L.STATUS_ERROR, LocalizeError("PROTOCOL_MISMATCH")), "error")
        end
    elseif record == "BEGIN" then
        local ttl = tonumber(fields[4])
        local expected = tonumber(fields[5])
        if not fields[3] or not ttl or ttl <= 0 or not expected then
            return
        end
        buildingPreview = {
            token = fields[3],
            expiresAt = GetTime() + ttl,
            expected = expected,
            items = {},
            ended = false,
        }
    elseif record == "ITEM" then
        if not buildingPreview or fields[3] ~= buildingPreview.token then
            return
        end
        local item = {
            guid = fields[4],
            entry = tonumber(fields[5]),
            quality = tonumber(fields[6]),
            itemLevel = tonumber(fields[7]),
            flags = tonumber(fields[8]),
            bag = tonumber(fields[9]),
            slot = tonumber(fields[10]),
        }
        if item.guid and item.entry and item.quality and item.itemLevel and item.flags and item.bag and item.slot then
            table.insert(buildingPreview.items, item)
        end
    elseif record == "END" then
        if not buildingPreview or fields[3] ~= buildingPreview.token then
            return
        end
        local receivedCount = tonumber(fields[4])
        buildingPreview.ended = receivedCount == buildingPreview.expected and receivedCount == #buildingPreview.items
    elseif record == "WARN" and fields[3] == "TRUNCATED" then
        if buildingPreview then
            buildingPreview.truncatedTotal = tonumber(fields[4]) or 0
        end
    elseif record == "EXCLUDED" then
        if fields[3] ~= activeToken then
            return
        end
        local index = FindPreviewItem(fields[4])
        if index then
            table.remove(previewItems, index)
        end
        if #previewItems == 0 then
            emptyState = "excluded"
        end
        SetStatus(string.format(L.STATUS_EXCLUDED, tonumber(fields[5]) or #previewItems), nil)
        RebuildRows()
    elseif record == "CANCELLED" then
        if fields[3] == activeToken then
            ClearPreview()
            emptyState = "cancelled"
            SetStatus(L.STATUS_CANCELLED, nil)
            RebuildRows()
        end
    elseif record == "SKIP" then
        SetStatus(string.format(L.STATUS_SKIPPED, LocalizeError(fields[4] or "SKIPPED")), "warning")
    elseif record == "RESULT" then
        if fields[3] == activeToken then
            local completed = tonumber(fields[4]) or 0
            local skipped = tonumber(fields[5]) or 0
            local mailed = tonumber(fields[6]) or 0
            ClearPreview()
            emptyState = "completed"
            SetStatus(string.format(L.STATUS_RESULT, completed, skipped, mailed), skipped > 0 and "warning" or "success")
            RebuildRows()
        end
    elseif record == "STATUS" then
        local enabled = tonumber(fields[3]) == 1
        local addonChannel = tonumber(fields[4]) == 1
        local serverProtocol = tonumber(fields[6])
        connected = enabled and addonChannel and serverProtocol == PROTOCOL_VERSION
        if connected then
            ShowReadyStatus()
        else
            SetStatus(L.STATUS_UNAVAILABLE, "error")
        end
    elseif record == "ERR" then
        local code = fields[3] or "UNKNOWN"
        if code == "TOKEN_EXPIRED" or code == "TOKEN_NOT_FOUND" or code == "TOKEN_MISMATCH" then
            ClearPreview()
            emptyState = code == "TOKEN_EXPIRED" and "expired" or "start"
            RebuildRows()
        end
        SetStatus(string.format(L.STATUS_ERROR, LocalizeError(code)), "error")
    end
    UpdateButtons()
end

local function HandleAddonMessage(prefix, message)
    if prefix ~= PREFIX or string.len(message) < 5 then
        return
    end

    local opcode = string.sub(message, 1, 1)
    local requestId = string.sub(message, 2, 5)
    local request = pending[requestId]
    if not request then
        return
    end

    if opcode == "m" then
        ParseRecord(string.sub(message, 6))
    elseif opcode == "o" then
        pending[requestId] = nil
        if request.kind == "preview" then
            CommitBuildingPreview()
        end
    elseif opcode == "f" then
        pending[requestId] = nil
        if request.kind == "preview" then
            buildingPreview = nil
            if emptyState ~= "expired" then
                emptyState = "start"
            end
            RebuildRows()
        end
    end
    UpdateButtons()
end

local function SaveFilters()
    ArcaneShredderDB.uncommon = controls.uncommon:GetChecked() and true or false
    ArcaneShredderDB.rare = controls.rare:GetChecked() and true or false
    ArcaneShredderDB.epic = controls.epic:GetChecked() and true or false
    ArcaneShredderDB.unbound = controls.unbound:GetChecked() and true or false
    ArcaneShredderDB.soulbound = controls.soulbound:GetChecked() and true or false
    ArcaneShredderDB.backpack = controls.backpack:GetChecked() and true or false
    for index = 1, 4 do
        ArcaneShredderDB["bag" .. index] = controls["bag" .. index]:GetChecked() and true or false
    end
    ArcaneShredderDB.maxItemLevel = tonumber(controls.maxItemLevel:GetText()) or 0
end

FiltersValid = function()
    if not (controls.uncommon:GetChecked() or controls.rare:GetChecked() or controls.epic:GetChecked()) then
        return false, L.FILTER_NEED_QUALITY
    end
    if not (controls.unbound:GetChecked() or controls.soulbound:GetChecked()) then
        return false, L.FILTER_NEED_BINDING
    end
    if not controls.backpack:GetChecked() then
        local hasBag = false
        for index = 1, 4 do
            if controls["bag" .. index]:GetChecked() then
                hasBag = true
                break
            end
        end
        if not hasBag then
            return false, L.FILTER_NEED_BAG
        end
    end
    return true, nil
end

local function FiltersChanged()
    SaveFilters()
    local valid, message = FiltersValid()
    if not valid then
        SetStatus(message, "error")
    elseif connected then
        SetStatus(L.STATUS_READY, "success")
    end
    UpdateButtons()
end

local function RestoreSafeDefaults()
    controls.uncommon:SetChecked(true)
    controls.rare:SetChecked(false)
    controls.epic:SetChecked(false)
    controls.unbound:SetChecked(true)
    controls.soulbound:SetChecked(true)
    controls.backpack:SetChecked(true)
    for index = 1, 4 do
        controls["bag" .. index]:SetChecked(true)
    end
    controls.maxItemLevel:SetText("0")
    SaveFilters()
    SetStatus(L.STATUS_SAFE_DEFAULTS, "success")
    UpdateButtons()
end

local function RequestPreview()
    SaveFilters()
    local valid, message = FiltersValid()
    if not valid then
        SetStatus(message, "error")
        UpdateButtons()
        return
    end

    ClearPreview()
    emptyState = "loading"
    RebuildRows()

    local qualityMask = 0
    if ArcaneShredderDB.uncommon then qualityMask = qualityMask + 4 end
    if ArcaneShredderDB.rare then qualityMask = qualityMask + 8 end
    if ArcaneShredderDB.epic then qualityMask = qualityMask + 16 end

    local bindingMask = 0
    if ArcaneShredderDB.unbound then bindingMask = bindingMask + 1 end
    if ArcaneShredderDB.soulbound then bindingMask = bindingMask + 2 end

    local bagMask = ArcaneShredderDB.backpack and 1 or 0
    for index = 1, 4 do
        if ArcaneShredderDB["bag" .. index] then
            bagMask = bagMask + math.pow(2, index)
        end
    end

    local maxItemLevel = math.floor(math.max(0, math.min(1000, ArcaneShredderDB.maxItemLevel)))
    ArcaneShredderDB.maxItemLevel = maxItemLevel
    controls.maxItemLevel:SetText(tostring(maxItemLevel))
    SetStatus(L.STATUS_CONNECTING, nil)
    SendRequest(string.format("ashred preview %d %d %d %d", qualityMask, maxItemLevel, bindingMask, bagMask), "preview")
end

local function RequestExclude(item)
    if activeToken and item and item.guid then
        SendRequest(string.format("ashred exclude %s %s", activeToken, item.guid), "exclude")
    end
end

local function RequestCancel()
    if activeToken then
        SendRequest("ashred cancel " .. activeToken, "cancel")
    end
end

local function ExpirePreview()
    StaticPopup_Hide("ARCANE_SHREDDER_CONFIRM")
    ClearPreview()
    emptyState = "expired"
    SetStatus(L.STATUS_EXPIRED, "error")
    RebuildRows()
end

local function RequestConfirm()
    if activeToken and #previewItems > 0 then
        if previewExpiresAt and GetTime() >= previewExpiresAt then
            ExpirePreview()
            return
        end
        SendRequest("ashred confirm " .. activeToken, "confirm")
    end
end

StaticPopupDialogs["ARCANE_SHREDDER_CONFIRM"] = {
    text = L.CONFIRM_TEXT,
    button1 = YES,
    button2 = NO,
    OnAccept = RequestConfirm,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    preferredIndex = 3,
}

local function CreateLabel(parent, text, x, y)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", x, y)
    label:SetText(text)
    return label
end

local function CreateCheck(parent, name, text, x, y, checked)
    local check = CreateFrame("CheckButton", name, parent, "OptionsCheckButtonTemplate")
    check:SetPoint("TOPLEFT", x, y)
    getglobal(name .. "Text"):SetText(text)
    check:SetChecked(checked)
    check:SetScript("OnClick", FiltersChanged)
    return check
end

local function CreateWindow()
    window = CreateFrame("Frame", "ArcaneShredderFrame", UIParent)
    window:SetWidth(700)
    window:SetHeight(640)
    window:SetPoint(ArcaneShredderDB.point or "CENTER", UIParent, ArcaneShredderDB.relativePoint or "CENTER",
        ArcaneShredderDB.x or 0, ArcaneShredderDB.y or 0)
    window:SetFrameStrata("DIALOG")
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relativePoint, x, y = self:GetPoint()
        ArcaneShredderDB.point = point
        ArcaneShredderDB.relativePoint = relativePoint
        ArcaneShredderDB.x = x
        ArcaneShredderDB.y = y
    end)
    window:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })

    local title = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -18)
    title:SetText(L.TITLE)

    local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -5, -5)

    local safetyText = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    safetyText:SetPoint("TOP", 0, -43)
    safetyText:SetText(L.SAFETY_NOTE)
    safetyText:SetTextColor(0.65, 0.82, 1)

    statusFrame = CreateFrame("Frame", nil, window)
    statusFrame:SetPoint("TOPLEFT", 18, -62)
    statusFrame:SetPoint("TOPRIGHT", -18, -62)
    statusFrame:SetHeight(32)
    statusFrame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 10,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    statusText = statusFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statusText:SetPoint("LEFT", 10, 0)
    statusText:SetPoint("RIGHT", -10, 0)
    statusText:SetJustifyH("LEFT")

    local filterPanel = CreateFrame("Frame", nil, window)
    filterPanel:SetPoint("TOPLEFT", 18, -104)
    filterPanel:SetPoint("TOPRIGHT", -18, -104)
    filterPanel:SetHeight(128)
    filterPanel:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 10,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    filterPanel:SetBackdropColor(0.04, 0.04, 0.04, 0.72)

    CreateLabel(filterPanel, L.QUALITY, 12, -12)
    controls.uncommon = CreateCheck(filterPanel, "ArcaneShredderUncommon", L.UNCOMMON, 6, -27, ArcaneShredderDB.uncommon)
    controls.rare = CreateCheck(filterPanel, "ArcaneShredderRare", L.RARE, 126, -27, ArcaneShredderDB.rare)
    controls.epic = CreateCheck(filterPanel, "ArcaneShredderEpic", L.EPIC, 226, -27, ArcaneShredderDB.epic)

    CreateLabel(filterPanel, L.BINDING, 365, -12)
    controls.unbound = CreateCheck(filterPanel, "ArcaneShredderUnbound", L.UNBOUND, 359, -27, ArcaneShredderDB.unbound)
    controls.soulbound = CreateCheck(filterPanel, "ArcaneShredderSoulbound", L.SOULBOUND, 490, -27, ArcaneShredderDB.soulbound)

    CreateLabel(filterPanel, L.BAGS, 12, -59)
    controls.backpack = CreateCheck(filterPanel, "ArcaneShredderBackpack", L.BACKPACK, 6, -74, ArcaneShredderDB.backpack)
    for index = 1, 4 do
        controls["bag" .. index] = CreateCheck(filterPanel, "ArcaneShredderBag" .. index, string.format(L.BAG, index),
            126 + (index - 1) * 98, -74, ArcaneShredderDB["bag" .. index])
    end

    CreateLabel(filterPanel, L.MAX_ITEM_LEVEL, 12, -111)
    controls.maxItemLevel = CreateFrame("EditBox", "ArcaneShredderMaxItemLevel", filterPanel, "InputBoxTemplate")
    controls.maxItemLevel:SetPoint("BOTTOMLEFT", 245, 6)
    controls.maxItemLevel:SetWidth(60)
    controls.maxItemLevel:SetHeight(22)
    controls.maxItemLevel:SetNumeric(true)
    controls.maxItemLevel:SetMaxLetters(4)
    controls.maxItemLevel:SetAutoFocus(false)
    controls.maxItemLevel:SetText(tostring(ArcaneShredderDB.maxItemLevel or 0))
    controls.maxItemLevel:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        FiltersChanged()
    end)

    controls.defaults = CreateFrame("Button", nil, filterPanel, "UIPanelButtonTemplate")
    controls.defaults:SetWidth(145)
    controls.defaults:SetHeight(24)
    controls.defaults:SetPoint("BOTTOMRIGHT", -10, 7)
    controls.defaults:SetText(L.SAFE_DEFAULTS)
    controls.defaults:SetScript("OnClick", RestoreSafeDefaults)

    summaryText = window:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    summaryText:SetPoint("TOPLEFT", 23, -247)
    expiryText = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    expiryText:SetPoint("TOPRIGHT", -43, -247)
    expiryText:SetJustifyH("RIGHT")

    local listBackground = CreateFrame("Frame", nil, window)
    listBackground:SetPoint("TOPLEFT", 18, -266)
    listBackground:SetPoint("BOTTOMRIGHT", -38, 93)
    listBackground:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    listBackground:SetBackdropColor(0.05, 0.05, 0.05, 0.85)

    for index = 1, ROW_COUNT do
        local row = CreateFrame("Button", nil, listBackground)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 8, -7 - (index - 1) * ROW_HEIGHT)
        row:SetPoint("TOPRIGHT", -8, -7 - (index - 1) * ROW_HEIGHT)
        row.highlight = row:CreateTexture(nil, "BACKGROUND")
        row.highlight:SetAllPoints(row)
        row.highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        row.highlight:SetBlendMode("ADD")
        row.highlight:Hide()
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetWidth(32)
        row.icon:SetHeight(32)
        row.icon:SetPoint("LEFT", 0, 0)
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -2)
        row.name:SetWidth(455)
        row.name:SetJustifyH("LEFT")
        row.details = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.details:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 2)
        row.details:SetWidth(455)
        row.details:SetJustifyH("LEFT")
        row.remove = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.remove:SetWidth(82)
        row.remove:SetHeight(26)
        row.remove:SetPoint("RIGHT", -3, 0)
        row.remove:SetText(L.EXCLUDE)
        row.remove:SetScript("OnClick", function()
            RequestExclude(row.item)
        end)
        row:SetScript("OnEnter", function(self)
            self.highlight:Show()
            if self.link then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(self.link)
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function(self)
            self.highlight:Hide()
            GameTooltip_Hide()
        end)
        rows[index] = row
    end

    scrollFrame = CreateFrame("ScrollFrame", "ArcaneShredderScrollFrame", listBackground, "FauxScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 0, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", 24, 8)
    scrollFrame:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, RebuildRows)
    end)

    window.emptyText = listBackground:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    window.emptyText:SetPoint("CENTER", 0, 0)
    window.emptyText:SetWidth(520)
    window.emptyText:SetJustifyH("CENTER")
    window.emptyText:SetText(L.EMPTY_START)

    previewButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
    previewButton:SetWidth(135)
    previewButton:SetHeight(30)
    previewButton:SetPoint("BOTTOMLEFT", 20, 42)
    previewButton:SetText(L.PREVIEW)
    previewButton:SetScript("OnClick", RequestPreview)

    confirmButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
    confirmButton:SetWidth(165)
    confirmButton:SetHeight(30)
    confirmButton:SetPoint("BOTTOM", 0, 42)
    confirmButton:SetText(L.CONFIRM)
    confirmButton:SetScript("OnClick", function()
        StaticPopup_Show("ARCANE_SHREDDER_CONFIRM", #previewItems)
    end)
    local confirmTexture = confirmButton:GetNormalTexture()
    if confirmTexture then
        confirmTexture:SetVertexColor(0.9, 0.28, 0.22)
    end

    cancelButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
    cancelButton:SetWidth(135)
    cancelButton:SetHeight(30)
    cancelButton:SetPoint("BOTTOMRIGHT", -20, 42)
    cancelButton:SetText(L.CANCEL)
    cancelButton:SetScript("OnClick", RequestCancel)

    SetStatus(L.STATUS_CONNECTING, nil)

    window:Hide()
    RebuildRows()
end

local function InitializeDatabase()
    if type(ArcaneShredderDB) ~= "table" then
        ArcaneShredderDB = {}
    end
    if ArcaneShredderDB.uncommon == nil then ArcaneShredderDB.uncommon = true end
    if ArcaneShredderDB.rare == nil then ArcaneShredderDB.rare = false end
    if ArcaneShredderDB.epic == nil then ArcaneShredderDB.epic = false end
    if ArcaneShredderDB.unbound == nil then ArcaneShredderDB.unbound = true end
    if ArcaneShredderDB.soulbound == nil then ArcaneShredderDB.soulbound = true end
    if ArcaneShredderDB.backpack == nil then ArcaneShredderDB.backpack = true end
    for index = 1, 4 do
        if ArcaneShredderDB["bag" .. index] == nil then
            ArcaneShredderDB["bag" .. index] = true
        end
    end
    ArcaneShredderDB.maxItemLevel = tonumber(ArcaneShredderDB.maxItemLevel) or 0
end

local function SendHello()
    connected = false
    SetStatus(L.STATUS_CONNECTING, false)
    SendRequest("ashred hello " .. PROTOCOL_VERSION, "hello")
end

SLASH_ARCANESHREDDER1 = "/ashred"
SlashCmdList["ARCANESHREDDER"] = function()
    if not window then
        return
    end
    if window:IsShown() then
        window:Hide()
    else
        window:Show()
        if not connected and not HasPendingRequest() then
            SendHello()
        end
    end
end

Addon:RegisterEvent("PLAYER_LOGIN")
Addon:RegisterEvent("CHAT_MSG_ADDON")
Addon:RegisterEvent("GET_ITEM_INFO_RECEIVED")
Addon:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        InitializeDatabase()
        RegisterAddonMessagePrefix(PREFIX)
        CreateWindow()
        helloScheduledAt = GetTime() + 1
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message = ...
        HandleAddonMessage(prefix, message)
    elseif event == "GET_ITEM_INFO_RECEIVED" and window and window:IsShown() then
        RebuildRows()
    end
end)

Addon:SetScript("OnUpdate", function()
    local now = GetTime()
    if helloScheduledAt and now >= helloScheduledAt then
        helloScheduledAt = nil
        SendHello()
    end

    local timedOut = false
    local confirmTimedOut = false
    local previewTimedOut = false
    for requestId, request in pairs(pending) do
        if now >= request.deadline then
            if request.kind == "preview" then
                buildingPreview = nil
                previewTimedOut = true
            elseif request.kind == "confirm" then
                confirmTimedOut = true
            end
            pending[requestId] = nil
            timedOut = true
        end
    end
    if timedOut then
        if confirmTimedOut then
            ClearPreview()
            emptyState = "start"
            RebuildRows()
        elseif previewTimedOut then
            emptyState = "start"
            RebuildRows()
        end
        connected = false
        SetStatus(L.STATUS_TIMEOUT, true)
        UpdateButtons()
    end

    if activeToken and previewExpiresAt and not HasPendingRequest() then
        if now >= previewExpiresAt then
            ExpirePreview()
        else
            local seconds = math.ceil(previewExpiresAt - now)
            if seconds ~= lastExpirySecond then
                lastExpirySecond = seconds
                UpdateSummary()
            end
        end
    end

    if window and window:IsShown() and window.needsItemRefresh and now - lastItemRefresh >= 1 then
        lastItemRefresh = now
        RebuildRows()
    end
end)
