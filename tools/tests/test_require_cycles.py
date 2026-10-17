"""No load-time require cycles between the mod's Lua modules.

In Kahlua, requiring a module that is still loading hands back nil, and a
`local X = require(...)` at the top of a file keeps that nil for the whole
session. A cycle Catalog -> Planner -> CaptureCursor -> BuildingCapture ->
WorldCatalog -> Catalog left WorldCatalog's Catalog nil, so every World lookup
"Find this piece" click raised "attempted index: open of non-table: null"
(WorldCatalog.openRecipe). The fix was structural: the sprite -> recipe index
moved to UI/WorldPieceIndex, a data module the planning tools use, and
WorldCatalog is only the context menu on top of it. The layering test keeps
the index and the planning tools from reaching the UI windows again.
"""
import re
import unittest

import kbw_runtime as k

# A require at the start of a line is a load-time require; ones indented inside
# functions run on demand and cannot form a load cycle.
TOP_LEVEL_REQUIRE = re.compile(r'^(?:local\s+\w+\s*=\s*)?require\s*\(?\s*["\'](KnoxBuildworks/[^"\']+)["\']', re.M)


def module_graph():
    modules = {}
    for root in k.LUA_ROOTS[:3]:
        for path in root.rglob("*.lua"):
            name = path.relative_to(root).with_suffix("").as_posix()
            modules.setdefault(name, path)
    return {
        name: [dep for dep in TOP_LEVEL_REQUIRE.findall(k.read_text(path)) if dep in modules]
        for name, path in modules.items()
    }


def find_cycle(graph):
    """First cycle found by depth-first search, as a module list, or None."""
    state = {}

    def visit(node, trail):
        state[node] = "open"
        for dep in graph.get(node, []):
            if state.get(dep) == "open":
                return trail[trail.index(dep):] + [dep]
            if dep not in state:
                found = visit(dep, trail + [dep])
                if found:
                    return found
        state[node] = "done"
        return None

    for node in sorted(graph):
        if node not in state:
            found = visit(node, [node])
            if found:
                return found
    return None


def reachable(graph, start):
    """Every module loaded, at load time, by loading start."""
    seen, stack = set(), [start]
    while stack:
        for dep in graph.get(stack.pop(), []):
            if dep not in seen:
                seen.add(dep)
                stack.append(dep)
    return seen


class RequireCycleTests(unittest.TestCase):
    def test_no_load_time_require_cycles(self):
        cycle = find_cycle(module_graph())
        self.assertIsNone(cycle, "require cycle: " + " -> ".join(cycle or []))

    def test_index_and_planning_tools_never_load_the_catalog_or_planning_windows(self):
        graph = module_graph()
        windows = {"KnoxBuildworks/UI/Catalog", "KnoxBuildworks/UI/PlanningMode", "KnoxBuildworks/UI/WorldCatalog"}
        for start in ("KnoxBuildworks/UI/WorldPieceIndex", "KnoxBuildworks/Planning/BuildingCapture",
                      "KnoxBuildworks/Planning/CaptureCursor", "KnoxBuildworks/Planning/PipetteCursor"):
            reached = reachable(graph, start)
            self.assertEqual(set(), reached & windows, f"{start} loads {sorted(reached & windows)}")

    def test_the_detector_finds_a_cycle(self):
        self.assertEqual(find_cycle({"a": ["b"], "b": ["c"], "c": ["a"]}), ["a", "b", "c", "a"])
        self.assertIsNone(find_cycle({"a": ["b"], "b": ["c"], "c": []}))


if __name__ == "__main__":
    unittest.main()
