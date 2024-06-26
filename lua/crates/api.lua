local semver = require("crates.semver")
local state = require("crates.state")
local time = require("crates.time")
local DateTime = time.DateTime
local types = require("crates.types")
local ApiFeatures = types.ApiFeatures
local ApiDependencyKind = types.ApiDependencyKind

local M = {
    ---@type table<string,CrateJob>
    crate_jobs = {},
    ---@type table<string,DepsJob>
    deps_jobs = {},
    ---@type table<string,SearchJob>
    search_jobs = {},
    ---@type QueuedJob[]
    queued_jobs = {},
    ---@type QueuedSearchJob[]
    search_queue = {},
    ---@type integer
    num_requests = 0,
}

---@class Job
---@field handle uv.uv_process_t|nil
---@field was_cancelled boolean|nil

---@class CrateJob
---@field job Job
---@field callbacks fun(crate: ApiCrate|nil, cancelled: boolean)[]

---@class DepsJob
---@field job Job
---@field callbacks fun(deps: ApiDependency[]|nil, cancelled: boolean)[]

---@class SearchJob
---@field job Job
---@field callbacks fun(search: ApiCrateSummary[]?, cancelled: boolean)[]

---@class QueuedJob
---@field kind JobKind
---@field name string
---@field crate_callbacks fun(crate: ApiCrate|nil, cancelled: boolean)[]
---@field version string
---@field deps_callbacks fun(deps: ApiDependency[]|nil, cancelled: boolean)[]

---@class QueuedSearchJob
---@field name string
---@field callbacks fun(deps: ApiCrateSummary[]?, cancelled: boolean)[]

---@enum JobKind
local JobKind = {
    CRATE = 1,
    DEPS = 2,
}

local SIGTERM = 15
local ENDPOINT = "https://crates.io/api/v1"
---@type string
local USERAGENT = vim.fn.shellescape("crates.nvim (https://github.com/saecki/crates.nvim)")

local DEPENDENCY_KIND_MAP = {
    ["normal"] = ApiDependencyKind.NORMAL,
    ["build"] = ApiDependencyKind.BUILD,
    ["dev"] = ApiDependencyKind.DEV,
}

---@class vim.json.DecodeOpts
---@class DecodeOpts
---@field luanil Luanil

---@class Luanil
---@field object boolean
---@field array boolean

---@type vim.json.DecodeOpts
local JSON_DECODE_OPTS = { luanil = { object = true, array = true } }


---comment
---@param json_str string
---@return table|nil
local function parse_json(json_str)
    ---@type any
    local json = vim.json.decode(json_str, JSON_DECODE_OPTS)
    if json and type(json) == "table" then
        return json
    end
end

---@param url string
---@param on_exit fun(data: string|nil, cancelled: boolean)
---@return Job|nil
local function start_job(url, on_exit)
    ---@type Job
    local job = {}
    ---@type uv.uv_pipe_t
    local stdout = vim.loop.new_pipe()

    ---@type string|nil
    local stdout_str = nil

    local opts = {
        args = { unpack(state.cfg.curl_args), "-A", USERAGENT, url },
        stdio = {nil, stdout, nil},
    }
    local handle, _pid
    ---@param code integer
    ---@param _signal integer
    ---@type uv.uv_process_t, integer
    handle, _pid = vim.loop.spawn("curl", opts, function(code, _signal)
        handle:close()

        local success = code == 0

        ---@type uv.uv_check_t
        local check = vim.loop.new_check()
        check:start(function()
            if not stdout:is_closing() then
                return
            end
            check:stop()

            vim.schedule(function()
                local data = success and stdout_str or nil
                on_exit(data, job.was_cancelled)
            end)
        end)
    end)

    if not handle then
        return nil
    end

    local accum = {}
    stdout:read_start(function(err, data)
        if err then
            stdout:read_stop()
            stdout:close()
            return
        end

        if data ~= nil then
            table.insert(accum, data)
        else
            stdout_str = table.concat(accum)
            stdout:read_stop()
            stdout:close()
        end
    end)

    job.handle = handle
    return job
end

---@param job Job
local function cancel_job(job)
    if job.handle then
        job.handle:kill(SIGTERM)
    end
end

---@param name string
---@param callbacks fun(crate: ApiCrate|nil, cancelled: boolean)[]
local function enqueue_crate_job(name, callbacks)
    for _, j in ipairs(M.queued_jobs) do
        if j.kind == JobKind.CRATE and j.name == name then
            vim.list_extend(j.crate_callbacks, callbacks)
            return
        end
    end

    table.insert(M.queued_jobs, {
        kind = JobKind.CRATE,
        name = name,
        crate_callbacks = callbacks,
    })
end

---@param name string
---@param version string
---@param callbacks fun(deps: ApiDependency[]|nil, cancelled: boolean)[]
local function enqueue_deps_job(name, version, callbacks)
    for _, j in ipairs(M.queued_jobs) do
        if j.kind == JobKind.DEPS and j.name == name and j.version == version then
            vim.list_extend(j.deps_callbacks, callbacks)
            return
        end
    end

    table.insert(M.queued_jobs, {
        kind = JobKind.DEPS,
        name = name,
        version = version,
        deps_callbacks = callbacks,
    })
end

---@param name string
---@param callbacks fun(search: ApiCrateSummary[]?, cancelled: boolean)[]
local function enqueue_search_job(name, callbacks)
    for _, j in ipairs(M.search_queue) do
        if j.name == name then
            vim.list_extend(j.callbacks, callbacks)
            return
        end
    end

    table.insert(M.search_queue, {
        name = name,
        callbacks = callbacks,
    })
end

---@param json_str string
---@return ApiCrateSummary[]?
function M.parse_search(json_str)
    local json = parse_json(json_str)
    if not (json and json.crates) then
        return
    end

    ---@type ApiCrateSummary[]
    local search = {}
    ---@diagnostic disable-next-line: no-unknown
    for _, c in ipairs(json.crates) do
        ---@type ApiCrateSummary
        local result = {
            name = c.name,
            description = c.description,
            newest_version = c.newest_version,
        }
        table.insert(search, result)
    end

    return search
end

---@param name string
---@param callbacks fun(search: ApiCrateSummary[]?, cancelled: boolean)[]
local function fetch_search(name, callbacks)
    local existing = M.search_jobs[name]
    if existing then
        vim.list_extend(existing.callbacks, callbacks)
        return
    end

    if M.num_requests >= state.cfg.max_parallel_requests then
        enqueue_search_job(name, callbacks)
        return
    end

    local url = string.format(
        "%s/crates?q=%s&per_page=%s",
        ENDPOINT,
        name,
        state.cfg.completion.crates.max_results
    )

    ---@param json_str string?
    ---@param cancelled boolean
    local function on_exit(json_str, cancelled)
        ---@type ApiCrateSummary[]?
        local search
        if not cancelled and json_str then
            local ok, s = pcall(M.parse_search, json_str)
            if ok then
                search = s
            end
        end
        for _, c in ipairs(callbacks) do
            c(search, cancelled)
        end

        M.search_jobs[name] = nil
        M.num_requests = M.num_requests - 1

        M.run_queued_jobs()
    end

    local job = start_job(url, on_exit)
    if job then
        M.num_requests = M.num_requests + 1
        M.search_jobs[name] = {
            job = job,
            callbacks = callbacks,
        }
    else
        for _, c in ipairs(callbacks) do
            c(nil, false)
        end
    end
end

---@param name string
---@return ApiCrateSummary[]?, boolean
function M.fetch_search(name)
    ---@param resolve fun(search: ApiCrateSummary[]?, cancelled: boolean)
    return coroutine.yield(function(resolve)
        fetch_search(name, { resolve })
    end)
end

---@param json_str string
---@return ApiCrate|nil
function M.parse_crate(json_str)
    local json = parse_json(json_str)
    if not (json and json.crate) then
        return nil
    end

    ---@type table<string,any>
    local c = json.crate
    ---@type ApiCrate
    local crate = {
        name = c.id,
        description = assert(c.description),
        created = assert(DateTime.parse_rfc_3339(c.created_at)),
        updated = assert(DateTime.parse_rfc_3339(c.updated_at)),
        downloads = assert(c.downloads),
        homepage = c.homepage,
        documentation = c.documentation,
        repository = c.repository,
        categories = {},
        keywords = {},
        versions = {},
    }

    ---@diagnostic disable-next-line: no-unknown
    for _, ct_id in ipairs(c.categories) do
        ---@diagnostic disable-next-line: no-unknown
        for _, ct in ipairs(json.categories) do
            if ct.id == ct_id then
                table.insert(crate.categories, ct.category)
            end
        end
    end

    ---@diagnostic disable-next-line: no-unknown
    for _, kw_id in ipairs(c.keywords) do
        ---@diagnostic disable-next-line: no-unknown
        for _, kw in ipairs(json.keywords) do
            if kw.id == kw_id then
                table.insert(crate.keywords, kw.keyword)
            end
        end
    end

    ---@diagnostic disable-next-line: no-unknown
    for _, v in ipairs(json.versions) do
        if v.num then
            ---@type ApiVersion
            local version = {
                num = v.num,
                features = ApiFeatures.new({}),
                yanked = v.yanked,
                parsed = semver.parse_version(v.num),
                created = assert(DateTime.parse_rfc_3339(v.created_at)),
            }

            ---@diagnostic disable-next-line: no-unknown
            for n, m in pairs(v.features) do
                table.sort(m)
                version.features:insert({
                    name = n,
                    members = m,
                })
            end

            -- add optional dependency members as features
            for _, f in ipairs(version.features.list) do
                for _, m in ipairs(f.members) do
                    -- don't add dependency features
                    if not string.find(m, "/") and not version.features:get_feat(m) then
                        version.features:insert({
                            name = m,
                            members = {},
                        })
                    end
                end
            end

            -- sort features alphabetically
            version.features:sort()

            -- add missing default feature
            if not version.features.list[1] or not (version.features.list[1].name == "default") then
                version.features:insert({
                    name = "default",
                    members = {},
                })
            end

            table.insert(crate.versions, version)
        end
    end


    return crate
end

---@param name string
---@param callbacks fun(crate: ApiCrate|nil, cancelled: boolean)[]
local function fetch_crate(name, callbacks)
    local existing = M.crate_jobs[name]
    if existing then
        vim.list_extend(existing.callbacks, callbacks)
        return
    end

    if M.num_requests >= state.cfg.max_parallel_requests then
        enqueue_crate_job(name, callbacks)
        return
    end

    local url = string.format("%s/crates/%s", ENDPOINT, name)

    ---@param json_str string|nil
    ---@param cancelled boolean
    local function on_exit(json_str, cancelled)
        ---@type ApiCrate|nil
        local crate
        if not cancelled and json_str then
            local ok, c = pcall(M.parse_crate, json_str)
            if ok then
                crate = c
            end
        end
        for _, c in ipairs(callbacks) do
            c(crate, cancelled)
        end

        M.crate_jobs[name] = nil
        M.num_requests = M.num_requests - 1

        M.run_queued_jobs()
    end

    local job = start_job(url, on_exit)
    if job then
        M.num_requests = M.num_requests + 1
        M.crate_jobs[name] = {
            job = job,
            callbacks = callbacks,
        }
    else
        for _, c in ipairs(callbacks) do
            c(nil, false)
        end
    end
end

---@param name string
---@return ApiCrate|nil, boolean
function M.fetch_crate(name)
    ---@param resolve fun(crate: ApiCrate|nil, cancelled: boolean)
    return coroutine.yield(function(resolve)
        fetch_crate(name, { resolve })
    end)
end

---@param json_str string
---@return ApiDependency[]|nil
function M.parse_deps(json_str)
    local json = parse_json(json_str)
    if not (json and json.dependencies) then
        return
    end

    ---@type ApiDependency[]
    local dependencies = {}
    ---@diagnostic disable-next-line: no-unknown
    for _, d in ipairs(json.dependencies) do
        if d.crate_id then
            ---@type ApiDependency
            local dependency = {
                name = d.crate_id,
                opt = d.optional or false,
                kind = DEPENDENCY_KIND_MAP[d.kind],
                vers = {
                    text = d.req,
                    reqs = semver.parse_requirements(d.req),
                },
            }
            table.insert(dependencies, dependency)
        end
    end

    return dependencies
end

---@param name string
---@param version string
---@param callbacks fun(deps: ApiDependency[]|nil, cancelled: boolean)[]
local function fetch_deps(name, version, callbacks)
    local jobname = name .. ":" .. version
    local existing = M.deps_jobs[jobname]
    if existing then
        vim.list_extend(existing.callbacks, callbacks)
        return
    end

    if M.num_requests >= state.cfg.max_parallel_requests then
        enqueue_deps_job(name, version, callbacks)
        return
    end

    local url = string.format("%s/crates/%s/%s/dependencies", ENDPOINT, name, version)

    ---@param json_str string
    ---@param cancelled boolean
    local function on_exit(json_str, cancelled)
        ---@type ApiDependency[]|nil
        local deps
        if not cancelled and json_str then
            local ok, d = pcall(M.parse_deps, json_str)
            if ok then
                deps = d
            end
        end
        for _, c in ipairs(callbacks) do
            c(deps, cancelled)
        end

        M.num_requests = M.num_requests - 1
        M.deps_jobs[jobname] = nil

        M.run_queued_jobs()
    end

    local job = start_job(url, on_exit)
    if job then
        M.num_requests = M.num_requests + 1
        M.deps_jobs[jobname] = {
            job = job,
            callbacks = callbacks,
        }
    else
        for _, c in ipairs(callbacks) do
            c(nil, false)
        end
    end
end

---@param name string
---@param version string
---@return ApiDependency[]|nil, boolean
function M.fetch_deps(name, version)
    ---@param resolve fun(deps: ApiDependency[]|nil, cancelled: boolean)
    return coroutine.yield(function(resolve)
        fetch_deps(name, version, { resolve })
    end)
end

---@param name string
---@return boolean
function M.is_fetching_crate(name)
    return M.crate_jobs[name] ~= nil
end

---@param name string
---@param version string
---@return boolean
function M.is_fetching_deps(name, version)
    return M.deps_jobs[name .. ":" .. version] ~= nil
end

---@param name string
---@return boolean
function M.is_fetching_search(name)
    return M.search_jobs[name] ~= nil
end

---@param name string
---@param callback fun(crate: ApiCrate|nil, cancelled: boolean)
local function add_crate_callback(name, callback)
    table.insert(
        M.crate_jobs[name].callbacks,
        callback
    )
end

---@param name string
---@return ApiCrate|nil, boolean
function M.await_crate(name)
    ---@param resolve fun(crate: ApiCrate|nil, cancelled: boolean)
    return coroutine.yield(function(resolve)
        add_crate_callback(name, resolve)
    end)
end

---@param name string
---@param version string
---@param callback fun(deps: ApiDependency[]|nil, cancelled: boolean)
local function add_deps_callback(name, version, callback)
    table.insert(
        M.deps_jobs[name .. ":" .. version].callbacks,
        callback
    )
end

---@param name string
---@param version string
---@return ApiDependency[]|nil, boolean
function M.await_deps(name, version)
    ---@param resolve fun(crate: ApiDependency[]|nil, cancelled: boolean)
    return coroutine.yield(function(resolve)
        add_deps_callback(name, version, resolve)
    end)
end

---@param name string
---@param callback fun(deps: ApiCrateSummary[]?, cancelled: boolean)
local function add_search_callback(name, callback)
    table.insert(
        M.search_jobs[name].callbacks,
        callback
    )
end

---@param name string
---@return ApiCrateSummary[]?, boolean
function M.await_search(name)
    ---@param resolve fun(crate: ApiCrateSummary[]?, cancelled: boolean)
    return coroutine.yield(function(resolve)
        add_search_callback(name, resolve)
    end)
end

function M.run_queued_jobs()
    -- Prioritise crate searches
    if #M.search_queue > 0 then
        local job = table.remove(M.search_queue, 1)
        fetch_search(job.name, job.search_callbacks)
        return
    end

    if #M.queued_jobs == 0 then
        return
    end

    local job = table.remove(M.queued_jobs, 1)
    if job.kind == JobKind.CRATE then
        fetch_crate(job.name, job.crate_callbacks)
    elseif job.kind == JobKind.DEPS then
        fetch_deps(job.name, job.version, job.deps_callbacks)
    end
end

function M.cancel_jobs()
    for _, r in pairs(M.crate_jobs) do
        cancel_job(r.job)
    end
    for _, r in pairs(M.deps_jobs) do
        cancel_job(r.job)
    end
    for _, r in pairs(M.search_jobs) do
        cancel_job(r.job)
    end

    M.crate_jobs = {}
    M.deps_jobs = {}
    M.search_jobs = {}
end

function M.cancel_search_jobs()
    for _, r in pairs(M.search_jobs) do
        cancel_job(r.job)
    end
    M.search_jobs = {}
end

return M
