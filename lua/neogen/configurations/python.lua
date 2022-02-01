local ts_utils = require("nvim-treesitter.ts_utils")
local nodes_utils = require("neogen.utilities.nodes")
local extractors = require("neogen.utilities.extractors")
local locator = require("neogen.locators.default")
local template = require("neogen.utilities.template")
local i = require("neogen.types.template").item

local parent = {
    func = { "function_definition" },
    class = { "class_definition" },
    file = { "module" },
    type = { "expression_statement" },
}

return {
    -- Search for these nodes
    parent = parent,

    -- Traverse down these nodes and extract the information as necessary
    data = {
        func = {
            ["function_definition"] = {
                ["0"] = {
                    extract = function(node)
                        local results = {}

                        local tree = {
                            {
                                retrieve = "all",
                                node_type = "parameters",
                                subtree = {
                                    { retrieve = "all", node_type = "identifier", extract = true },

                                    {
                                        retrieve = "all",
                                        node_type = "default_parameter",
                                        subtree = { { retrieve = "all", node_type = "identifier", extract = true } },
                                    },
                                    {
                                        retrieve = "all",
                                        node_type = "typed_parameter",
                                        extract = true,
                                    },
                                    {
                                        retrieve = "all",
                                        node_type = "typed_default_parameter",
                                        as = "typed_parameter",
                                        extract = true,
                                        subtree = { { retrieve = "all", node_type = "identifier", extract = true } },
                                    },
                                },
                            },
                            {
                                retrieve = "first",
                                node_type = "block",
                                subtree = {
                                    {
                                        retrieve = "all",
                                        node_type = "return_statement",
                                        recursive = true,
                                        subtree = {
                                            {
                                                retrieve = "all",
                                                node_type = "true|false|integer|binary_operator|expression_list|call",
                                                as = "anonymous_return",
                                                extract = true,
                                            },
                                            {
                                                retrieve = "all",
                                                node_type = "identifier",
                                                as = "return_statement",
                                                extract = true,
                                            },
                                        },
                                    },
                                },
                            },
                            {
                                retrieve = "all",
                                node_type = "type",
                                as = i.ReturnTypeHint,
                                extract = true,
                            },
                        }
                        local nodes = nodes_utils:matching_nodes_from(node, tree)
                        if nodes["typed_parameter"] then
                            results["typed_parameters"] = {}
                            for _, n in pairs(nodes["typed_parameter"]) do
                                local type_subtree = {
                                    { retrieve = "all", node_type = "identifier", extract = true, as = i.Parameter },
                                    { retrieve = "all", node_type = "type", extract = true, as = i.Type },
                                }
                                local typed_parameters = nodes_utils:matching_nodes_from(n, type_subtree)
                                typed_parameters = extractors:extract_from_matched(typed_parameters)
                                table.insert(results["typed_parameters"], typed_parameters)
                            end
                        end
                        local res = extractors:extract_from_matched(nodes)

                        if nodes["anonymous_return"] then
                            local _res = extractors:extract_from_matched(nodes, { type = true })
                            res.anonymous_return = _res.anonymous_return
                        end

                        -- Return type hints takes precedence over all other types for generating template
                        if res[i.ReturnTypeHint] then
                            res["return_statement"] = nil
                            res["anonymous_return"] = nil
                            if res[i.ReturnTypeHint][1] == "None" then
                                res[i.ReturnTypeHint] = nil
                            end
                        end

                        -- Check if the function is inside a class
                        -- If so, remove reference to the first parameter (that can be `self`, `cls`, or a custom name)
                        if res.identifier and locator({ current = node }, parent.class) then
                            local remove_identifier = true
                            -- Check if function is a static method. If so, will not remove the first parameter
                            if node:parent():type() == "decorated_definition" then
                                local decorator = nodes_utils:matching_child_nodes(node:parent(), "decorator")
                                decorator = ts_utils.get_node_text(decorator[1])[1]
                                if decorator == "@staticmethod" then
                                    remove_identifier = false
                                end
                            end
                            if remove_identifier then
                                table.remove(res.identifier, 1)
                                if vim.tbl_isempty(res.identifier) then
                                    res.identifier = nil
                                end
                            end
                        end

                        results[i.HasParameter] = (res.typed_parameter or res.identifier) and { true } or nil
                        results[i.Type] = res.type
                        results[i.Parameter] = res.identifier
                        results[i.ReturnAnonym] = res.anonymous_return
                        results[i.Return] = res.return_statement
                        results[i.ReturnTypeHint] = res[i.ReturnTypeHint]
                        results[i.HasReturn] = (res.return_statement or res.anonymous_return or res[i.ReturnTypeHint])
                                and { true }
                            or nil
                        return results
                    end,
                },
            },
        },
        class = {
            ["class_definition"] = {
                ["0"] = {
                    extract = function(node)
                        local results = {}
                        local tree = {
                            {
                                retrieve = "first",
                                node_type = "block",
                                subtree = {
                                    {
                                        retrieve = "first",
                                        node_type = "function_definition",
                                        subtree = {
                                            {
                                                retrieve = "first",
                                                node_type = "block",
                                                subtree = {
                                                    {
                                                        retrieve = "all",
                                                        node_type = "expression_statement",
                                                        subtree = {
                                                            {
                                                                retrieve = "first",
                                                                node_type = "assignment",
                                                                extract = true,
                                                            },
                                                        },
                                                    },
                                                },
                                            },
                                        },
                                    },
                                },
                            },
                        }

                        local nodes = nodes_utils:matching_nodes_from(node, tree)

                        if vim.tbl_isempty(nodes) then
                            return {}
                        end

                        results[i.ClassAttribute] = {}
                        for _, assignment in pairs(nodes["assignment"]) do
                            local left_side = assignment:field("left")[1]
                            local left_attribute = left_side:field("attribute")[1]
                            left_attribute = ts_utils.get_node_text(left_attribute)[1]
                            if left_attribute and not vim.startswith(left_attribute, "_") then
                                table.insert(results[i.ClassAttribute], left_attribute)
                            end
                        end
                        if vim.tbl_isempty(results[i.ClassAttribute]) then
                            results[i.ClassAttribute] = nil
                        end

                        return results
                    end,
                },
            },
        },
        file = {
            ["module"] = {
                ["0"] = {
                    extract = function()
                        return {}
                    end,
                },
            },
        },
        type = {
            ["0"] = {
                extract = function()
                    return {}
                end,
            },
        },
    },

    -- Use default granulator and generator
    locator = nil,
    granulator = nil,
    generator = nil,

    template = template
        :config({
            append = { position = "after", child_name = "comment", fallback = "block" }, -- optional: where to append the text (default_generator)
            position = function(node, type)
                if type == "file" then
                    -- Checks if the file starts with #!, that means it's a shebang line
                    -- We will then write file annotations just after it
                    for child in node:iter_children() do
                        if child:type() == "comment" then
                            local start_row = child:start()
                            if start_row == 0 then
                                if vim.startswith(ts_utils.get_node_text(node, 0)[1], "#!") then
                                    return 1, 0
                                end
                            end
                        end
                    end
                    return 0, 0
                end
            end,
        })
        :add_default_template("google_docstrings")
        :add_template("numpydoc")
        :add_template("reST"),
}
