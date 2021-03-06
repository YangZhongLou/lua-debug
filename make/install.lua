local platform, luamake = ...

if not platform then
    local OS = require 'bee.platform'.OS
    if OS == 'Windows' then
        platform = 'msvc'
    elseif OS == 'macOS' then
        platform = 'macos'
    elseif OS == 'Linux' then
        platform = 'linux'
    end
end

if not luamake then
    luamake = 'luamake'
end

print 'Step 1. init'

local fs = require 'bee.filesystem'
local sp = require 'bee.subprocess'
local root = fs.absolute(fs.path '.')
local outputDir = root / 'publish'

local version = (function()
    for line in io.lines((root / 'project' / 'windows' / 'common.props'):string()) do
        local ver = line:match('<Version>(%d+%.%d+%.%d+)</Version>')
        if ver then
            print('version: ', ver)
            return ver
        end
    end
    error 'Cannot found version in common.props.'
end)()

local function copy_directory(from, to, filter)
    fs.create_directories(to)
    for fromfile in from:list_directory() do
        if fs.is_directory(fromfile) then
            copy_directory(fromfile, to / fromfile:filename(), filter)
        else
            if (not filter) or filter(fromfile) then
                fs.copy_file(fromfile, to / fromfile:filename(), true)
            end
        end
    end
end

local function io_load(filepath)
    local f = assert(io.open(filepath:string(), 'rb'))
    local buf = f:read 'a'
    f:close()
    return buf
end

local function io_save(filepath, buf)
    local f = assert(io.open(filepath:string(), 'wb'))
    f:write(buf)
    f:close()
end

print 'Step 2. remove old file'
fs.remove_all(outputDir)

print 'Step 3. update version'
local function update_version(filename, pattern)
    local str = io_load(filename)
    local find_pattern = pattern:gsub('[%^%$%(%)%%%.%[%]%+%-%?]', '%%%0'):gsub('{}', '%%d+%%.%%d+%%.%%d+')
    local replace_pattern = pattern:gsub('{}', version)
    local t = {}
    while true do
        local first, last = str:find(find_pattern)
        if first then
            t[#t+1] = str:sub(1, first-1)
            t[#t+1] = replace_pattern
            str = str:sub(last+1)
        else
            break
        end
    end
    t[#t+1] = str
    io_save(filename, table.concat(t))
end
update_version(root / 'extension' / 'package.json', '"version": "{}"')
update_version(root / '.vscode' / 'launch.json', 'actboy168.lua-debug-{}')

print 'Step 4. copy extension'
copy_directory(root / 'extension', outputDir,
    function (path)
        local ext = path:extension():string():lower()
        return (ext ~= '.dll') and (ext ~= '.exe')
    end
)

if platform == 'msvc' then
    print 'Step 5. compile launcher x86'
    assert(sp.spawn {
        luamake, 'remake', '-f', 'make-launcher.lua', '-arch', 'x86',
        cwd = root,
        searchPath = true,
    }):wait()
    print 'Step 6. compile launcher x64'
    assert(sp.spawn {
        luamake, 'remake', '-f', 'make-launcher.lua', '-arch', 'x64',
        cwd = root,
        searchPath = true,
    }):wait()
    print 'Step 7. compile bee'
else
    print 'Step 5. compile bee'
end

assert(sp.spawn {
    luamake, 'remake', '-f', 'make-bin.lua',
    cwd = root,
    searchPath = true,
}):wait()

if platform == 'msvc' then
    print 'Step 8. compile lua53 x86'
    assert(sp.spawn {
        luamake, 'remake', '-f', 'make-runtime.lua', '-arch', 'x86', '-luaver', 'lua53',
        cwd = root,
        searchPath = true,
    }):wait()

    print 'Step 9. compile lua53 x64'
    assert(sp.spawn {
        luamake, 'remake', '-f', 'make-runtime.lua', '-arch', 'x64', '-luaver', 'lua53',
        cwd = root,
        searchPath = true,
    }):wait()

    print 'Step 10. compile lua54 x86'
    assert(sp.spawn {
        luamake, 'remake', '-f', 'make-runtime.lua', '-arch', 'x86', '-luaver', 'lua54',
        cwd = root,
        searchPath = true,
    }):wait()

    print 'Step 11. compile lua54 x64'
    assert(sp.spawn {
        luamake, 'remake', '-f', 'make-runtime.lua', '-arch', 'x64', '-luaver', 'lua54',
        cwd = root,
        searchPath = true,
    }):wait()
else
    print 'Step 6. compile lua53'
    assert(sp.spawn {
        luamake, 'remake', '-f', 'make-runtime.lua', '-luaver', 'lua53',
        cwd = root,
        searchPath = true,
    }):wait()

    print 'Step 7. compile lua54'
    assert(sp.spawn {
        luamake, 'remake', '-f', 'make-runtime.lua', '-luaver', 'lua54',
        cwd = root,
        searchPath = true,
    }):wait()
end

print 'finish.'
