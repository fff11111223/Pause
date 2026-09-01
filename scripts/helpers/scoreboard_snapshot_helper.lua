local ScoreboardHelper = require "scripts.helpers.scoreboard_helper"
local StatisticsDB = Managers.state.statistics_db

local function get_all_scoreboard_stats()
    local stats = {}
    local stats_id = Managers.state.game_stats:stats_id()
    for _, group in ipairs(ScoreboardHelper.scoreboard_grouped_topic_stats) do
        if group.group_name == "offense" then
            for _, stat_name in ipairs(group.stats) do
                for _, topic in ipairs(ScoreboardHelper.scoreboard_topic_stats) do
                    if topic.name == stat_name then
                        local value = nil
                        if topic.stat_types then
                            local total = 0
                            for _, stat_type in ipairs(topic.stat_types) do
                                total = total + StatisticsDB:get_stat(stats_id, unpack(stat_type))
                            end
                            value = total
                        else
                            value = StatisticsDB:get_stat(stats_id, topic.stat_type)
                        end
                        stats[stat_name] = value
                        break
                    end
                end
            end
        end
    end
    return stats
end

local function apply_all_scoreboard_stats(saved_stats)
    local stats_id = Managers.state.game_stats:stats_id()
    for name, value in pairs(saved_stats) do
        for _, topic in ipairs(ScoreboardHelper.scoreboard_topic_stats) do
            if topic.name == name then
                if topic.stat_types then
                    for _, stat_type in ipairs(topic.stat_types) do
                        StatisticsDB:set_stat(stats_id, stat_type, value)
                    end
                else
                    StatisticsDB:set_stat(stats_id, topic.stat_type, value)
                end
                break
            end
        end
    end
end

return {
    get_all_scoreboard_stats = get_all_scoreboard_stats,
    apply_all_scoreboard_stats = apply_all_scoreboard_stats,
}
