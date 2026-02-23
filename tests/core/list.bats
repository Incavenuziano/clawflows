#!/usr/bin/env bats
# Tests for the list command

load '../test_helper'

setup() {
    setup_test_environment
}

teardown() {
    teardown_test_environment
}

# ============================================================================
# Basic List Tests
# ============================================================================

@test "list: shows enabled community workflows" {
    create_community_workflow "workflow-a" "🅰️" "Workflow A"
    create_community_workflow "workflow-b" "🅱️" "Workflow B"
    enable_workflow "workflow-a"

    run_clawflows list

    assert_success
    assert_output --partial "Community — Enabled (1)"
    assert_output --partial "workflow-a"
}

@test "list: shows available community workflows" {
    create_community_workflow "workflow-a" "🅰️" "Workflow A"
    create_community_workflow "workflow-b" "🅱️" "Workflow B"
    enable_workflow "workflow-a"

    run_clawflows list

    assert_success
    assert_output --partial "Community — Available (1)"
    assert_output --partial "workflow-b"
}

@test "list enabled: only shows enabled workflows" {
    create_community_workflow "workflow-a" "🅰️" "Workflow A"
    create_community_workflow "workflow-b" "🅱️" "Workflow B"
    enable_workflow "workflow-a"

    run_clawflows list enabled

    assert_success
    assert_output --partial "Community — Enabled (1)"
    assert_output --partial "workflow-a"
    refute_output --partial "workflow-b"
}

@test "list available: only shows available workflows" {
    create_community_workflow "workflow-a" "🅰️" "Workflow A"
    create_community_workflow "workflow-b" "🅱️" "Workflow B"
    enable_workflow "workflow-a"

    run_clawflows list available

    assert_success
    assert_output --partial "Community — Available (1)"
    assert_output --partial "workflow-b"
    refute_output --partial "Enabled"
}

@test "list: shows 'no workflows enabled' when none enabled" {
    create_community_workflow "workflow-a" "🅰️" "Workflow A"

    run_clawflows list enabled

    assert_success
    assert_output --partial "No workflows enabled"
}

@test "list: with empty directories shows 'no workflows'" {
    run_clawflows list

    assert_success
    assert_output --partial "No workflows found"
}

# ============================================================================
# Display Tests
# ============================================================================

@test "list: shows emoji and description" {
    create_community_workflow "test-workflow" "🧪" "A test workflow description"
    enable_workflow "test-workflow"

    run_clawflows list

    assert_success
    assert_output --partial "🧪"
    assert_output --partial "test-workflow"
    assert_output --partial "A test workflow description"
}

@test "list: skips .gitkeep files" {
    create_community_workflow "real-workflow" "🧪" "Real workflow"
    touch "${COMMUNITY_DIR}/.gitkeep"

    run_clawflows list

    assert_success
    assert_output --partial "real-workflow"
    refute_output --partial ".gitkeep"
}

@test "list: custom workflows override community by name" {
    create_community_workflow "shared-name" "🌍" "Community version"
    create_custom_workflow "shared-name" "🏠" "Custom version"

    run_clawflows list

    assert_success
    # Should show custom version's description
    assert_output --partial "Custom version"
    # Should NOT show community version
    refute_output --partial "Community version"
}

# ============================================================================
# Count Tests
# ============================================================================

@test "list: counts community enabled correctly" {
    create_community_workflow "wf-1" "1️⃣" "First"
    create_community_workflow "wf-2" "2️⃣" "Second"
    create_community_workflow "wf-3" "3️⃣" "Third"
    enable_workflow "wf-1"
    enable_workflow "wf-2"

    run_clawflows list

    assert_success
    assert_output --partial "Community — Enabled (2)"
    assert_output --partial "Community — Available (1)"
}

@test "list: all filter shows everything" {
    create_community_workflow "wf-enabled" "✅" "Enabled one"
    create_community_workflow "wf-available" "📦" "Available one"
    enable_workflow "wf-enabled"

    run_clawflows list all

    assert_success
    assert_output --partial "Community — Enabled (1)"
    assert_output --partial "Community — Available (1)"
}

# ============================================================================
# Custom vs Community Section Tests
# ============================================================================

@test "list: custom workflows appear in 'Your Workflows' section" {
    create_custom_workflow "my-workflow" "🏠" "My custom workflow"

    run_clawflows list

    assert_success
    assert_output --partial "Your Workflows"
    assert_output --partial "my-workflow"
}

@test "list: enabled custom workflow shows in 'Your Workflows — Enabled'" {
    create_custom_workflow "my-workflow" "🏠" "My custom workflow"
    enable_workflow "my-workflow"

    run_clawflows list

    assert_success
    assert_output --partial "Your Workflows — Enabled (1)"
    assert_output --partial "my-workflow"
}

@test "list: available custom workflow shows in 'Your Workflows — Available'" {
    create_custom_workflow "my-workflow" "🏠" "My custom workflow"

    run_clawflows list

    assert_success
    assert_output --partial "Your Workflows — Available (1)"
    assert_output --partial "my-workflow"
}

@test "list: community workflows appear in 'Community' section" {
    create_community_workflow "comm-workflow" "🌍" "Community workflow"

    run_clawflows list

    assert_success
    assert_output --partial "Community"
    assert_output --partial "comm-workflow"
}

@test "list: custom and community workflows shown in separate sections" {
    create_custom_workflow "my-workflow" "🏠" "My custom one"
    create_community_workflow "comm-workflow" "🌍" "Community one"
    enable_workflow "my-workflow"
    enable_workflow "comm-workflow"

    run_clawflows list

    assert_success
    assert_output --partial "Your Workflows — Enabled (1)"
    assert_output --partial "Community — Enabled (1)"
    assert_output --partial "my-workflow"
    assert_output --partial "comm-workflow"
}

@test "list: mixed custom and community with enabled and available" {
    create_custom_workflow "custom-on" "🏠" "Custom enabled"
    create_custom_workflow "custom-off" "🏡" "Custom available"
    create_community_workflow "comm-on" "🌍" "Community enabled"
    create_community_workflow "comm-off" "🌎" "Community available"
    enable_workflow "custom-on"
    enable_workflow "comm-on"

    run_clawflows list

    assert_success
    assert_output --partial "Your Workflows — Enabled (1)"
    assert_output --partial "Your Workflows — Available (1)"
    assert_output --partial "Community — Enabled (1)"
    assert_output --partial "Community — Available (1)"
}

@test "list: filter enabled with custom and community" {
    create_custom_workflow "custom-on" "🏠" "Custom enabled"
    create_custom_workflow "custom-off" "🏡" "Custom available"
    create_community_workflow "comm-on" "🌍" "Community enabled"
    enable_workflow "custom-on"
    enable_workflow "comm-on"

    run_clawflows list enabled

    assert_success
    assert_output --partial "Your Workflows — Enabled (1)"
    assert_output --partial "Community — Enabled (1)"
    refute_output --partial "Available"
}

@test "list: filter available with custom and community" {
    create_custom_workflow "custom-on" "🏠" "Custom enabled"
    create_community_workflow "comm-off" "🌎" "Community available"
    enable_workflow "custom-on"

    run_clawflows list available

    assert_success
    assert_output --partial "Community — Available (1)"
    refute_output --partial "Enabled"
    refute_output --partial "Your Workflows"
}

@test "list: omits empty sections" {
    create_community_workflow "comm-workflow" "🌍" "Community one"

    run_clawflows list

    assert_success
    refute_output --partial "Your Workflows"
    assert_output --partial "Community — Available (1)"
}
