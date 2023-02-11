-- Interface powered memory object editor.

local gui = require 'gui'
local json = require 'json'
local dialog = require 'gui.dialogs'
local widgets = require 'gui.widgets'
local guiScript = require 'gui.script'
local utils = require 'utils'

config = config or json.open('dfhack-config/gm-editor.json')

local REFRESH_MS = 100


find_funcs = find_funcs or (function()
    local t = {}
    for k in pairs(df) do
        pcall(function()
            t[k] = df[k].find
        end)
    end
    return t
end)()

local keybindings_raw = {
    {name='offset', key="CUSTOM_ALT_O",desc="Show current items offset"},
    {name='find', key="CUSTOM_F",desc="Find a value by entering a predicate"},
    {name='find_id', key="CUSTOM_I",desc="Find object with this ID, using ref-target if available"},
    {name='find_id_raw', key="CUSTOM_SHIFT_I",desc="Find object with this ID, forcing dialog box"},
    {name='lua_set', key="CUSTOM_ALT_S",desc="Set by using a lua function"},
    {name='insert', key="CUSTOM_ALT_I",desc="Insert a new value to the vector"},
    {name='delete', key="CUSTOM_ALT_D",desc="Delete selected entry"},
    {name='reinterpret', key="CUSTOM_ALT_R",desc="Open selected entry as something else"},
    {name='start_filter', key="CUSTOM_S",desc="Start typing filter, Enter to finish"},
    {name='help', key="STRING_A063",desc="Show this help"},
    {name='displace', key="STRING_A093",desc="Open reference offseted by index"},
    {name='autoupdate', key="CUSTOM_ALT_A",desc="Automatically keep values updated"},
    --{name='NOT_USED', key="SEC_SELECT",desc="Edit selected entry as a number (for enums)"}, --not a binding...
}

local keybindings = {}
for _, v in ipairs(keybindings_raw) do
    keybindings[v.name] = v
end

function getTypeName(type)
    return tostring(type):gmatch('<type: (.+)>')() or '<unknown type>'
end
function getTargetFromScreens()
    local my_trg
    if dfhack.gui.getCurFocus() == 'item' then
        my_trg=dfhack.gui.getCurViewscreen().item
    elseif dfhack.gui.getCurFocus() == 'joblist' then
        local t_screen=dfhack.gui.getCurViewscreen()
        my_trg=t_screen.jobs[t_screen.cursor_pos]
    elseif dfhack.gui.getCurFocus() == 'createquota' then
        local t_screen=dfhack.gui.getCurViewscreen()
        my_trg=t_screen.orders[t_screen.sel_idx]
    elseif dfhack.gui.getCurFocus() == 'dwarfmode/LookAround/Flow' then
        local t_look=df.global.ui_look_list.items[df.global.ui_look_cursor]
        my_trg=t_look.data.Flow

    elseif dfhack.gui.getSelectedUnit(true) then
        my_trg=dfhack.gui.getSelectedUnit(true)
    elseif dfhack.gui.getSelectedItem(true) then
        my_trg=dfhack.gui.getSelectedItem(true)
    elseif dfhack.gui.getSelectedJob(true) then
        my_trg=dfhack.gui.getSelectedJob(true)
    else
        qerror("No valid target found")
    end
    return my_trg
end
function search_relevance(search, candidate)
    local function clean(str)
        return ' ' .. str:lower():gsub('[^a-z0-9]','') .. ' '
    end
    search = clean(search)
    candidate = clean(candidate)
    local ret = 0
    while #search > 0 do
        local pos = candidate:find(search:sub(1, 1), 1, true)
        if pos then
            ret = ret + (#search - pos)
            candidate = candidate:sub(pos + 1)
        end
        search = search:sub(2)
    end
    return ret
end


GmEditorUi = defclass(GmEditorUi, widgets.Window)
GmEditorUi.ATTRS{
    frame=config.data,
    frame_title="GameMaster's editor",
    frame_inset=0,
    resizable=true,
    resize_min={w=30, h=20},
}

function burning_red(input) -- todo does not work! bug angavrilov that so that he would add this, very important!!
    local col=COLOR_LIGHTRED
    return {text=input,pen=dfhack.pen.parse{fg=COLOR_LIGHTRED,bg=0}}
end
function Disclaimer(tlb)
    local dsc={
        "Association Of ", {text="Psychic ",pen=COLOR_YELLOW}, "Dwarves (AOPD) is not responsible for all the damage", NEWLINE,
        "that this tool can (and will) cause to you and your loved dwarves", NEWLINE,
        "and/or saves. Please use with caution.", NEWLINE,
        {text="Magma not included.", pen=COLOR_LIGHTRED,bg=0}
    }
    if tlb then
        for _,v in ipairs(dsc) do
            table.insert(tlb,v)
        end
    end
    return dsc
end

function GmEditorUi:init(args)
    if not next(self.frame) then
        self.frame = {w=80, h=50}
    end

    self.stack={}
    self.item_count=0
    self.keys={}
    local helptext={{text="Help"},NEWLINE,NEWLINE}
    for _,v in ipairs(keybindings_raw) do
        table.insert(helptext,{text=v.desc,key=v.key,key_sep=': '})
        table.insert(helptext,NEWLINE)
    end
    table.insert(helptext,NEWLINE)
    Disclaimer(helptext)

    local helpPage=widgets.Panel{
        subviews={widgets.Label{text=helptext,frame = {l=1,t=1,yalign=0}}}}
    local mainList=widgets.List{view_id="list_main",choices={},frame = {l=1,t=3,yalign=0},on_submit=self:callback("editSelected"),
        on_submit2=self:callback("editSelectedRaw"),
        text_pen=COLOR_GREY, cursor_pen=COLOR_YELLOW}
    local mainPage=widgets.Panel{
        subviews={
            mainList,
            widgets.Label{text={{text="<no item>",id="name"},{gap=1,text="Help",key=keybindings.help.key,key_sep = '()'}}, view_id = 'lbl_current_item',frame = {l=1,t=1,yalign=0}},
            widgets.EditField{frame={l=1,t=2,h=1},label_text="Search",key=keybindings.start_filter.key,key_sep='(): ',on_change=self:callback('text_input'),view_id="filter_input"},
        widgets.ToggleHotkeyLabel{label="Auto-Update", key=keybindings.autoupdate.key, initial_option=false, view_id = 'lbl_autoupdate', frame={l=1,t=0,yalign=0}}}
        ,view_id='page_main'}

    self:addviews{widgets.Pages{subviews={mainPage,helpPage},view_id="pages"}}
    self:pushTarget(args.target)
end
function GmEditorUi:verifyStack(args)
    local failure = false

    local last_good_level = nil

    for i, level in pairs(self.stack) do
        local obj=level.target

        local keys = level.keys
        local selection = level.selected
        local sel_key = keys[selection]
        local next_by_ref
        local status, _ = pcall(
        function()
            next_by_ref = obj[sel_key]
            end
        )
        if not status then
            failure = true
            last_good_level = i - 1
            break
        end
        if not self.stack[i+1] == next_by_ref then
            failure = true
            break
        end
    end
    if failure then
        self.stack = {table.unpack(self.stack, 1, last_good_level)}
        return false
    else
        return true
    end
end
function GmEditorUi:text_input(new_text)
    self:updateTarget(true,true)
end
function GmEditorUi:find(test)
    local trg=self:currentTarget()

    if test== nil then
        dialog.showInputPrompt("Test function","Input function that tests(k,v as argument):",COLOR_WHITE,"",dfhack.curry(self.find,self))
        return
    end

    local e,what=load("return function(k,v) return "..test.." end")
    if e==nil then
        dialog.showMessage("Error!","function failed to compile\n"..what,COLOR_LIGHTRED)
    end

    if trg.target and trg.target._kind and trg.target._kind=="container" then

        for k,v in pairs(trg.target) do
            if e()(k,v)==true then
                self:pushTarget(v)
                return
            end
        end
    else
        local i=1
        for k,v in pairs(trg.target) do
            if e()(k,v)==true then
                self.subviews.list_main:setSelected(i)
                return
            end
            i=i+1
        end
    end
end
function GmEditorUi:find_id(force_dialog)
    local key = tostring(self:getSelectedKey())
    local id = tonumber(self:getSelectedValue())
    local field = self:getSelectedField()
    local ref_target = nil
    if field and field.ref_target then
        ref_target = field.ref_target
    end
    if ref_target and not force_dialog then
        if not ref_target.find then
            dialog.showMessage("Error!", ("Cannot look up %s by ID"):format(getmetatable(ref_target)), COLOR_LIGHTRED)
            return
        end
        local obj = ref_target.find(id)
        if obj then
            self:pushTarget(obj)
        else
            dialog.showMessage("Error!", ("%s with ID %d not found"):format(getmetatable(ref_target), id), COLOR_LIGHTRED)
        end
        return
    end
    if not id then return end
    local raw_message
    local search_key = key
    if ref_target then
        search_key = getmetatable(ref_target)
        raw_message = 'This field has a ref-target of ' .. search_key
        if not ref_target.get_vector then
            raw_message = raw_message .. '\nbut this type does not have an instance vector'
        end
    else
        raw_message = 'This field has no ref-target specified. If you\n' ..
                      'know what it should be, please report it!'
    end
    local opts = {}
    for name, func in pairs(find_funcs) do
        table.insert(opts, {text=name, callback=func, weight=search_relevance(search_key, name)})
    end
    table.sort(opts, function(a, b)
        return a.weight > b.weight
    end)
    local message = {{pen=COLOR_LIGHTRED, text="Note: "}}
    for _, line in ipairs(raw_message:split('\n')) do
        table.insert(message, line)
        table.insert(message, NEWLINE)
    end
    guiScript.start(function()
        local ret,idx,choice=guiScript.showListPrompt("Choose type:",message,COLOR_WHITE,opts,nil,true)
        if ret then
            local obj = choice.callback(id)
            if obj then
                self:pushTarget(obj)
            else
                dialog.showMessage("Error!", ('%s with ID %d not found'):format(choice.text, id), COLOR_LIGHTRED)
            end
        end
    end)
end
function GmEditorUi:insertNew(typename)
    local tp=typename
    if typename == nil then
        dialog.showInputPrompt("Class type","You can:\n * Enter type name (without 'df.')\n * Leave empty for default type and 'nil' value\n * Enter '*' for default type and 'new' constructed pointer value",COLOR_WHITE,"",self:callback("insertNew"))
        return
    end

    local trg=self:currentTarget()
    if trg.target and trg.target._kind and trg.target._kind=="container" then
        if tp == "" then
            trg.target:resize(#trg.target+1)
        elseif tp== "*" then
            trg.target:insert("#",{new=true})
        else
            local ntype=df[tp]
            if ntype== nil then
                dialog.showMessage("Error!","Type '"..tp.." not found",COLOR_RED)
                return
            end
            trg.target:insert("#",{new=ntype})
        end
        self:updateTarget(true,true)
    end
end
function GmEditorUi:deleteSelected(key)
    local trg=self:currentTarget()
    if trg.target and trg.target._kind and trg.target._kind=="container" then
        trg.target:erase(key)
        self:updateTarget(true,true)
    end
end
function GmEditorUi:getSelectedKey()
    return self:currentTarget().keys[self.subviews.list_main:getSelected()]
end
function GmEditorUi:getSelectedValue()
    return self:currentTarget().target[self:getSelectedKey()]
end
function GmEditorUi:getSelectedField()
    local ok, ret = pcall(function()
        return self:currentTarget().target:_field(self:getSelectedKey())
    end)
    if ok then
        return ret
    end
end
function GmEditorUi:currentTarget()
    return self.stack[#self.stack]
end
function GmEditorUi:getSelectedEnumType()
    local trg=self:currentTarget()
    local trg_key=trg.keys[self.subviews.list_main:getSelected()]

    local ok,ret=pcall(function () --super safe way to check if the field has enum
        return trg.target._field==nil or trg.target:_field(trg_key)==nil
    end)
    if not ok or ret==true then
        return nil
    end

    local enum=trg.target:_field(trg_key)._type
    if enum._kind=="enum-type" then
        return enum
    else
        return nil
    end
end
function GmEditorUi:editSelectedEnum(index,choice)
    local enum=self:getSelectedEnumType()
    if enum then
        local trg=self:currentTarget()
        local trg_key=self:getSelectedKey()
        local list={}
        for i=enum._first_item, enum._last_item do
            table.insert(list,{text=('%s (%i)'):format(tostring(enum[i]), i),value=i})
        end
        guiScript.start(function()
            local ret,idx,choice=guiScript.showListPrompt("Choose "..getTypeName(enum).." item:",nil,3,list,nil,true)
            if ret then
                trg.target[trg_key]=choice.value
                self:updateTarget(true)
            end
        end)

    else
        qerror("not an enum")
    end
end
function GmEditorUi:openReinterpret(key)
    local trg=self:currentTarget()
    dialog.showInputPrompt(tostring(trg_key),"Enter new type:",COLOR_WHITE,
                "",function(choice)
                    local ntype=df[choice]
                    self:pushTarget(df.reinterpret_cast(ntype,trg.target[key]))
                end)
end
function GmEditorUi:openOffseted(index,choice)
    local trg=self:currentTarget()
    local trg_key=trg.keys[index]
    dialog.showInputPrompt(tostring(trg_key),"Enter offset:",COLOR_WHITE,"",
        function(choice)
            self:pushTarget(trg.target[trg_key]:_displace(tonumber(choice)))
        end)
end
function GmEditorUi:editSelectedRaw(index,choice)
    self:editSelected(index, choice, {raw=true})
end
function GmEditorUi:editSelected(index,choice,opts)
    if not self:verifyStack() then
        self:updateTarget()
        return
    end
    opts = opts or {}
    local trg=self:currentTarget()
    local trg_key=trg.keys[index]
    if trg.target and trg.target._kind and trg.target._kind=="bitfield" then
        trg.target[trg_key]= not trg.target[trg_key]
        self:updateTarget(true)
    else
        local trg_type=type(trg.target[trg_key])
        if self:getSelectedEnumType() and not opts.raw then
            self:editSelectedEnum()
        elseif trg_type=='number' or trg_type=='string' then --ugly TODO: add metatable get selected
            local prompt = "Enter new value:"
            if self:getSelectedEnumType() then
                prompt = "Enter new " .. getTypeName(trg.target:_field(trg_key)._type) .. " value"
            end
            dialog.showInputPrompt(tostring(trg_key), prompt, COLOR_WHITE,
                tostring(trg.target[trg_key]), self:callback("commitEdit",trg_key))

        elseif trg_type == 'boolean' then
            trg.target[trg_key] = not trg.target[trg_key]
            self:updateTarget(true)
        elseif trg_type == 'userdata' or trg_type == 'table' then
            self:pushTarget(trg.target[trg_key])
        elseif trg_type == 'nil' or trg_type == 'function' then
            -- ignore
        else
            print("Unknown type:"..trg_type)
            pcall(function() print("Subtype:"..tostring(trg.target[trg_key]._kind)) end)
        end
    end
end

function GmEditorUi:commitEdit(key,value)
    local trg=self:currentTarget()
    if type(trg.target[key])=='number' then
        trg.target[key]=tonumber(value)
    elseif type(trg.target[key])=='string' then
        trg.target[key]=value
    end
    self:updateTarget(true)
end

function GmEditorUi:set(key,input)
    local trg=self:currentTarget()

    if input== nil then
        dialog.showInputPrompt("Set to what?","Lua code to set to (v cur target):",COLOR_WHITE,"",self:callback("set",key))
        return
    end
    local e,what=load("return function(v) return "..input.." end")
    if e==nil then
        dialog.showMessage("Error!","function failed to compile\n"..what,COLOR_LIGHTRED)
        return
    end
    trg.target[key]=e()(trg)
    self:updateTarget(true)
end
function GmEditorUi:onInput(keys)
    if GmEditorUi.super.onInput(self, keys) then return true end

    if keys.LEAVESCREEN or keys._MOUSE_R_DOWN then
        if self.subviews.pages:getSelected()==2 then
            self.subviews.pages:setSelected(1)
        else
            self:popTarget()
        end
        return true
    end

    if self.subviews.pages:getSelected() == 2 then
        return false
    end

    if keys[keybindings.offset.key] then
        local trg=self:currentTarget()
        local _,stoff=df.sizeof(trg.target)
        local size,off=df.sizeof(trg.target:_field(self:getSelectedKey()))
        dialog.showMessage("Offset",string.format("Size hex=%x,%x dec=%d,%d\nRelative hex=%x dec=%d",size,off,size,off,off-stoff,off-stoff),COLOR_WHITE)
        return true
    elseif keys[keybindings.displace.key] then
        self:openOffseted(self.subviews.list_main:getSelected())
        return true
    elseif keys[keybindings.find.key] then
        self:find()
        return true
    elseif keys[keybindings.find_id.key] then
        self:find_id()
        return true
    elseif keys[keybindings.find_id_raw.key] then
        self:find_id(true)
        return true
    elseif keys[keybindings.lua_set.key] then
        self:set(self:getSelectedKey())
        return true
    elseif keys[keybindings.insert.key] then --insert
        self:insertNew()
        return true
    elseif keys[keybindings.delete.key] then --delete
        self:deleteSelected(self:getSelectedKey())
        return true
    elseif keys[keybindings.reinterpret.key] then
        self:openReinterpret(self:getSelectedKey())
        return true
    elseif keys[keybindings.help.key] then
        self.subviews.pages:setSelected(2)
        return true
    end
end

function getStringValue(trg,field)
    local obj=trg.target

    local text=tostring(obj[field])
    pcall(function()
    if obj._field ~= nil then
        local enum=obj:_field(field)._type
        if enum._kind=="enum-type" then
            text=text.." ("..tostring(enum[obj[field]])..")"
        end
        local ref_target=obj:_field(field).ref_target
        if ref_target then
            text=text.. " (ref-target: "..getmetatable(ref_target)..")"
        end
    end
    end)
    return text
end
function GmEditorUi:updateTarget(preserve_pos,reindex)
    self:verifyStack()
    local trg=self:currentTarget()
    local filter=self.subviews.filter_input.text:lower()

    if reindex then
        trg.keys={}
        for k,v in pairs(trg.target) do
            if filter~= "" then
                local ok,ret=dfhack.pcall(string.match,tostring(k):lower(),filter)
                if not ok then
                    table.insert(trg.keys,k)
                elseif ret then
                    table.insert(trg.keys,k)
                end
            else
                table.insert(trg.keys,k)
            end
        end
    end
    self.subviews.lbl_current_item:itemById('name').text=tostring(trg.target)
    local t={}
    for k,v in pairs(trg.keys) do
            table.insert(t,{text={{text=string.format("%-25s",tostring(v))},{gap=1,text=getStringValue(trg,v)}}})
    end
    local last_pos
    if preserve_pos then
        last_pos=self.subviews.list_main:getSelected()
    end
    self.subviews.list_main:setChoices(t)
    if last_pos then
        self.subviews.list_main:setSelected(last_pos)
    else
        self.subviews.list_main:setSelected(trg.selected)
    end
    self.next_refresh_ms = dfhack.getTickCount() + REFRESH_MS
end
function GmEditorUi:pushTarget(target_to_push)
    local new_tbl={}
    new_tbl.target=target_to_push
    new_tbl.keys={}
    new_tbl.selected=1
    new_tbl.filter=""
    if self:currentTarget()~=nil then
        self:currentTarget().selected=self.subviews.list_main:getSelected()
        self.stack[#self.stack].filter=self.subviews.filter_input.text
    end
    for k,v in pairs(target_to_push) do
        table.insert(new_tbl.keys,k)
    end
    new_tbl.item_count=#new_tbl.keys
    table.insert(self.stack,new_tbl)
    self.subviews.filter_input:setText("")
    self:updateTarget()
end
function GmEditorUi:popTarget()
    table.remove(self.stack) --removes last element
    if #self.stack==0 then
        self.parent_view:dismiss()
        return
    end
    self.subviews.filter_input:setText(self.stack[#self.stack].filter) --restore filter
    self:updateTarget()
end
eval_env = utils.df_shortcut_env()
function eval(s)
    local f, err = load("return " .. s, "expression", "t", eval_env)
    if err then qerror(err) end
    return f()
end
function GmEditorUi:postUpdateLayout()
    config:write(self.frame)
end

function GmEditorUi:onRenderBody()
    if self.subviews.lbl_autoupdate:getOptionValue() and self.next_refresh_ms <= dfhack.getTickCount()  then
        self:updateTarget()
    end
end

GmScreen = defclass(GmScreen, gui.ZScreen)
GmScreen.ATTRS {
    focus_path='gm-editor',
}

function GmScreen:init(args)
    local target = args.target
    if not target then
        qerror('Target not found')
    end
    self:addviews{GmEditorUi{view_id='main', target=target}}
end

function GmScreen:onDismiss()
    view = nil
end

local function get_editor(args)
    if #args~=0 then
        if args[1]=="dialog" then
            dialog.showInputPrompt("Gm Editor", "Object to edit:", COLOR_GRAY,
            "", function(entry)
                view = GmScreen{target=eval(entry)}:show()
            end)
        elseif args[1]=="free" then
            return GmScreen{target=df.reinterpret_cast(df[args[2]],args[3])}:show()
        else
            return GmScreen{target=eval(args[1])}:show()
        end
    else
        return GmScreen{target=getTargetFromScreens()}:show()
    end
end

view = view and view:raise() or get_editor{...}
