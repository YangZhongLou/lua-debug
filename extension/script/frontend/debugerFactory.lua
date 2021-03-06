local fs = require 'bee.filesystem'
local sp = require 'bee.subprocess'
local platformOS = require 'frontend.platformOS'
local inject = require 'inject'

local useWSL = false
local useUtf8 = false

local function initialize(args)
    useWSL = args.useWSL
    useUtf8 = args.sourceCoding == "utf8"
end

local function towsl(s)
    if not useWSL or not s:match "^%a:" then
        return s
    end
    return s:gsub("\\", "/"):gsub("^(%a):", function(c)
        return "/mnt/"..c:lower()
    end)
end

local function nativepath(s)
    if not useWSL and not useUtf8 and platformOS() == "Windows" then
        local unicode = require 'bee.unicode'
        return unicode.u2a(s)
    end
    return towsl(s)
end

local function create_install_script(args, port, dbg, runtime)
    local res = {}
    if type(args.path) == "string" then
        res[#res+1] = ("package.path=[[%s]];"):format(nativepath(args.path))
    elseif type(args.path) == "table" then
        local path = {}
        for _, v in ipairs(args.path) do
            if type(v) == "string" then
                path[#path+1] = nativepath(v)
            end
        end
        res[#res+1] = ("package.path=[[%s]];"):format(table.concat(path, ";"))
    end
    if type(args.cpath) == "string" then
        res[#res+1] = ("package.cpath=[[%s]];"):format(nativepath(args.cpath))
    elseif type(args.cpath) == "table" then
        local path = {}
        for _, v in ipairs(args.cpath) do
            if type(v) == "string" then
                path[#path+1] = nativepath(v)
            end
        end
        res[#res+1] = ("package.cpath=[[%s]];"):format(table.concat(path, ";"))
    end

    if not args.deprecationServer then
        local ext = platformOS() == "Windows" and "dll" or "so"
        res[#res+1] = ("local path=[[%s]];"):format(nativepath(dbg))
        res[#res+1] = ("local rdebug=assert(package.loadlib(path..'%s/remotedebug.%s','luaopen_remotedebug'))();"):format(runtime, ext)
        res[#res+1] = ("local dbg=assert(loadfile(path..[[/script/start_debug.lua]]))(rdebug,path,'/script/?.lua','%s/?.%s');"):format(runtime, ext)
    else
        runtime = runtime:sub(1,-2).."3"
        res[#res+1] = ("local path,rt=[[%s]],[[%s]];"):format(nativepath(dbg), runtime)
        res[#res+1] = "local dbg=assert(package.loadlib(path..rt..'/debugger.dll', 'luaopen_debugger'))();"
    end
    res[#res+1] = ("package.loaded[ [[%s]] ]=dbg;dbg:io([[pipe:%s]])"):format(
        (type(args.internalModule) == "string") and args.internalModule or "debugger",
        towsl(port:string())
    )

    if type(args.outputCapture) == "table" then
        for _, v in ipairs(args.outputCapture) do
            if type(v) == "string" then
                res[#res+1] = (":redirect('%s')"):format(v);
            end
        end
    end
    res[#res+1] = ":guard():wait():start()"
    return table.concat(res)
end

local function is64Exe(exe)
    local f = io.open(exe:string())
    if not f then
        return
    end
    local MZ = f:read(2)
    if MZ ~= 'MZ' then
        f:close()
        return
    end
    f:seek('set', 60)
    local e_lfanew = ('I4'):unpack(f:read(4))
    f:seek('set', e_lfanew)
    local ntheader = ('z'):unpack(f:read(4) .. '\0')
    if ntheader ~= 'PE' then
        f:close()
        return
    end
    f:seek('cur', 18)
    local characteristics = ('I2'):unpack(f:read(2))
    f:close()
    return (characteristics & 0x100) == 0
end

local function getLuaRuntime(args)
    if args.luaRuntime == "5.4 64bit" then
        return 54, 64
    elseif args.luaRuntime == "5.4 32bit" then
        return 54, 32
    elseif args.luaRuntime == "5.3 64bit" then
        return 53, 64
    elseif args.luaRuntime == "5.3 32bit" then
        return 53, 32
    end
    return 53, 32
end

local function getLuaExe(args, dbg)
    local runtime = 'runtime'
    local ver, bit = getLuaRuntime(args)
    local luaexe
    if type(args.luaexe) == "string" then
        luaexe = fs.path(args.luaexe)

        if platformOS() == "Windows" then
            if is64Exe(luaexe) then
                runtime = runtime .. "/win64"
            else
                runtime = runtime .. "/win32"
            end
        else
            runtime = runtime .. "/" .. platformOS():lower()
        end
        if ver == 53 then
            runtime = runtime .. "/lua53"
        else
            runtime = runtime .. "/lua54"
        end
    else
        if platformOS() == "Windows" then
            if bit == 64 then
                runtime = runtime .. "/win64"
            else
                runtime = runtime .. "/win32"
            end
        else
            runtime = runtime .. "/" .. platformOS():lower()
        end
        if ver == 53 then
            runtime = runtime .. "/lua53"
        else
            runtime = runtime .. "/lua54"
        end
        luaexe = dbg / runtime / (platformOS() == "Windows" and "lua.exe" or "lua")
    end
    return luaexe, '/'..runtime
end

local function installBootstrap1(option, luaexe, args)
    option.cwd = (type(args.cwd) == "string") and args.cwd or luaexe:parent_path():string()
    if type(args.env) == "table" then
        option.env = args.env
    end
end

local function installBootstrap2(c, luaexe, args, port, dbg, runtime)
    if args.useWSL then
        c[#c+1] = "wsl"
    end
    c[#c+1] = towsl(luaexe:string())
    c[#c+1] = "-e"
    c[#c+1] = create_install_script(args, port, dbg:string(), runtime)

    if type(args.arg0) == "string" then
        c[#c+1] = args.arg0
    elseif type(args.arg0) == "table" then
        for _, v in ipairs(args.arg0) do
            if type(v) == "string" then
                c[#c+1] = v
            end
        end
    end

    c[#c+1] = (type(args.program) == "string") and towsl(args.program) or ".lua"

    if type(args.arg) == "string" then
        c[#c+1] = args.arg
    elseif type(args.arg) == "table" then
        for _, v in ipairs(args.arg) do
            if type(v) == "string" then
                c[#c+1] = v
            end
        end
    end
end

local function create_terminal(args, dbg, port)
    initialize(args)
    local luaexe, runtime = getLuaExe(args, dbg)
    local option = {
        kind = (args.console == "integratedTerminal") and "integrated" or "external",
        title = "Lua Debug",
        args = {},
    }
    installBootstrap1(option, luaexe, args)
    installBootstrap2(option.args, luaexe, args, port, dbg, runtime)
    return option
end

local function create_luaexe(args, dbg, port)
    initialize(args)
    local luaexe, runtime = getLuaExe(args, dbg)
    local option = {
        console = 'hide'
    }
    installBootstrap1(option, luaexe, args)
    installBootstrap2(option, luaexe, args, port, dbg, runtime)
    if not args.luadll or type(args.luaexe) == "string" then
        return sp.spawn(option)
    end
    option.suspended = true
    local process, err = sp.spawn(option)
    if not process then
        return process, err
    end
    inject.replacedll(process
        , getLuaRuntime(args) == 53 and "lua53.dll" or "lua54.dll"
        , args.luadll
    )
    process:resume()
    return process
end

local function create_process(args)
    initialize(args)
    local noinject = args.noInject
    local application = args.runtimeExecutable
    local option = {
        application,
        env = args.env,
        console = 'new',
        cwd = args.cwd or fs.path(application):parent_path(),
        suspended = not noinject,
    }
    local process
    if type(args.runtimeArgs) == 'string' then
        option.argsStyle = 'string'
        option[2] = args.runtimeArgs
        process = sp.spawn(option)
    elseif type(args.runtimeArgs) == 'table' then
        option[2] = args.runtimeArgs
        process = sp.spawn(option)
    else
        process = sp.spawn(option)
    end
    if noinject then
        return process
    end
    if not args.deprecationServer then
        inject.injectdll(process
            , (WORKDIR / "bin" / "win" / "launcher.x86.dll"):string()
            , (WORKDIR / "bin" / "win" / "launcher.x64.dll"):string()
            , "launch"
        )
    else
        inject.injectdll(process
            , (WORKDIR / "runtime" / "win32" / "lua53" / "debugger-inject.dll"):string()
            , (WORKDIR / "runtime" / "win64" / "lua53" / "debugger-inject.dll"):string()
            , "launch"
        )
    end
    process:resume()
    return process
end

return {
    create_terminal = create_terminal,
    create_process = create_process,
    create_luaexe = create_luaexe,
}
