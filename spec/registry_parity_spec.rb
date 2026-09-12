require "edupage/cli"
require "edupage/server/api"

# The guard that makes "same capabilities everywhere" a fact rather than an intention.
#
# Every resource declared in the registry must appear, with the same name and the same
# parameters, as a CLI command, a REST route and an MCP tool. Adding a resource without
# wiring it into all three is impossible while these pass - and so is quietly renaming a
# filter on one surface.
RSpec.describe "surface parity" do
  let(:resources) { Edupage::Registry.all }
  let(:cli_commands) { Edupage::CLI.commands }
  let(:rest_routes) { Edupage::Server::API.routes["GET"].map { |route| route[0].to_s } }
  let(:mcp_tools) { Edupage::Server::MCP.new.tools.map(&:to_h) }

  it "declares at least the resources this tool is about" do
    expect(Edupage::Registry.names).to include(
      :account, :schools, :students, :teachers, :classes, :subjects, :periods,
      :timetable, :lessons, :assignments, :homeworks, :timeline, :years, :terms, :grades
    )
  end

  describe "every resource" do
    it "has a CLI command" do
      missing = resources.reject { |r| cli_commands.key?(r.name.to_s) }

      expect(missing.map(&:name)).to be_empty
    end

    it "has a REST route derived from its scope" do
      missing = resources.reject { |r| rest_routes.any? { |route| route.include?(r.rest_path) } }

      expect(missing.map(&:name)).to be_empty
    end

    it "has an MCP tool" do
      names = mcp_tools.map { |tool| tool[:name] }
      missing = resources.reject { |r| names.include?(r.tool_name) }

      expect(missing.map(&:name)).to be_empty
    end

    it "offers the same filters on the CLI as in the registry" do
      resources.each do |resource|
        expected = resource.own_params.map(&:name)
        next if expected.empty?

        command_options = Edupage::CLI.commands[resource.name.to_s].options.keys.map(&:to_sym)

        expect(command_options).to include(*expected),
                                   "#{resource.name} is missing CLI options " \
                                   "#{(expected - command_options).inspect}"
      end
    end

    it "offers the same parameters in MCP as in the registry" do
      by_name = mcp_tools.to_h { |tool| [tool[:name], tool] }

      resources.each do |resource|
        properties = by_name.fetch(resource.tool_name)[:inputSchema][:properties].keys.map(&:to_s)

        expect(properties).to match_array(resource.all_params.map { |p| p.name.to_s }),
                              "#{resource.tool_name} input schema does not match the registry"
      end
    end

    it "marks the chain levels required in MCP so no level can be skipped" do
      by_name = mcp_tools.to_h { |tool| [tool[:name], tool] }

      resources.each do |resource|
        required = by_name.fetch(resource.tool_name)[:inputSchema][:required]
        # The year is the deliberate exception: it defaults to the current one.
        expected = resource.scope_chain - [:year]

        expect(required).to match_array(expected.map(&:to_s)),
                            "#{resource.tool_name} should require #{expected.inspect}, requires #{required.inspect}"
      end
    end

    it "leaves the CLI's scope options optional so Thor does not pre-empt the error" do
      # Marking them required in Thor would fail every command with "No value provided
      # for required options" instead of listing what could be chosen - and would break
      # commands that need no scope at all, such as `schools` and `login`.
      %i[school student year].each do |name|
        expect(Edupage::CLI.class_options[name].required?).to be(false)
      end
    end

    it "carries scope parameters into the REST path" do
      resources.each do |resource|
        scope_params = resource.scope_params.map(&:name)

        scope_params.each do |param|
          next unless resource.scope_chain.include?(param)

          expect(resource.rest_path).to include(":#{param}"),
                                        "#{resource.name} REST path is missing :#{param}"
        end
      end
    end
  end

  describe "read-only guarantees" do
    it "exposes no HTTP verb other than GET" do
      %w[POST PUT PATCH DELETE].each do |verb|
        paths = Edupage::Server::API.routes.fetch(verb, []).map { |route| route[0].to_s }
        # /mcp is the exception: JSON-RPC needs POST, and its tools are read-only.
        expect(paths.reject { |p| p.include?("/mcp") }).to be_empty
      end
    end

    it "marks every MCP tool read-only" do
      expect(mcp_tools).to all(include(annotations: hash_including(readOnlyHint: true)))
    end

    it "never references a write endpoint" do
      # These are the Edupage endpoints that change something. None may appear in lib/.
      writes = %w[createItem createReply homeworkFlag uploadAtt getOnlineLessonOpenUrl
                  createConfirmation]
      offenders = Dir[File.expand_path("../lib/**/*.rb", __dir__)].select do |file|
        content = File.read(file)
        writes.any? { |endpoint| content.include?(endpoint) }
      end

      expect(offenders).to be_empty
    end
  end

  describe "resource declarations" do
    it "gives every resource a summary and a resolver" do
      resources.each { |resource| expect { resource.validate! }.not_to raise_error }
    end

    it "uses a known scope" do
      expect(resources.map(&:scope).uniq - Edupage::Registry::SCOPES.keys).to be_empty
    end

    it "names enum parameters with their allowed values" do
      resources.flat_map(&:own_params).select(&:enum?).each do |param|
        expect(param.values).not_to be_empty, "#{param.name} is an enum with no values"
      end
    end
  end
end
