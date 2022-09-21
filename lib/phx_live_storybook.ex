defmodule PhxLiveStorybook.BackendBehaviour do
  @moduledoc """
  Behaviour implemented by your backend module.
  """

  alias PhxLiveStorybook.{FolderEntry, StoryEntry}

  @doc """
  Returns a configuration value from your config.exs storybook settings.

  `key` is the config key
  `default` is an optional default value if no value can be fetched.
  """
  @callback config(key :: atom(), default :: any()) :: any()

  @doc """
  Returns a precompiled tree of your storybook stories.
  """
  @callback content_tree() :: [%FolderEntry{} | %StoryEntry{}]

  @doc """
  Returns all the leaves (only stories) of the storybook content tree.
  """
  @callback leaves() :: [%StoryEntry{}]

  @doc """
  Returns all the nodes (stoires & folders) of the storybook content tree as a flat list.
  """
  @callback flat_list() :: [%FolderEntry{} | %StoryEntry{}]

  @doc """
  Returns an entry from its absolute storybook path (not filesystem).
  """
  @callback find_entry_by_path(String.t()) :: %FolderEntry{} | %StoryEntry{}

  @doc """
  Retuns a storybook path from a story module.
  """
  @callback storybook_path(atom()) :: String.t()
end

defmodule PhxLiveStorybook do
  @external_resource "README.md"
  @moduledoc @external_resource
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  alias PhxLiveStorybook.CodeHelpers
  alias PhxLiveStorybook.Entries
  alias PhxLiveStorybook.StoryValidator

  require Logger

  @doc false
  defmacro __using__(opts) do
    {opts, _} = Code.eval_quoted(opts, [], __CALLER__)
    opts = merge_opts_and_config(opts, __CALLER__.module)

    [
      main_quote(opts),
      recompilation_quotes(opts),
      config_quotes(opts),
      stories_quotes(opts)
    ]
  end

  defp merge_opts_and_config(opts, backend_module) do
    config_opts = Application.get_env(opts[:otp_app], backend_module, [])
    Keyword.merge(opts, config_opts)
  end

  defp main_quote(opts) do
    quote do
      @behaviour PhxLiveStorybook.BackendBehaviour

      @impl PhxLiveStorybook.BackendBehaviour
      def storybook_path(story_module) do
        if Code.ensure_loaded?(story_module) do
          content_path = Keyword.get(unquote(opts), :content_path)

          file_path =
            story_module.__info__(:compile)[:source]
            |> to_string()
            |> String.replace_prefix(content_path, "")
            |> String.replace_suffix(Entries.story_file_suffix(), "")
        end
      end
    end
  end

  # This quote triggers recompilation for the module whenever a new file or any index file under
  # content_path has been touched.
  defp recompilation_quotes(opts) do
    content_path =
      Keyword.get_lazy(opts, :content_path, fn -> raise "content_path key must be set" end)

    components_pattern = Path.join(content_path, "**/*")
    index_pattern = Path.join(content_path, "**/*#{Entries.index_file_suffix()}")

    quote do
      @index_paths Path.wildcard(unquote(index_pattern))
      @paths Path.wildcard(unquote(components_pattern))
      @paths_hash :erlang.md5(@paths)

      for index_path <- @index_paths do
        @external_resource index_path
      end

      def __mix_recompile__? do
        if unquote(components_pattern) do
          unquote(components_pattern) |> Path.wildcard() |> :erlang.md5() !=
            @paths_hash
        else
          false
        end
      end
    end
  end

  @doc false
  defp stories_quotes(opts) do
    content_tree = content_tree(opts)
    entries = Entries.flat_list(content_tree)
    leaves = Entries.leaves(content_tree)

    find_entry_by_path_quotes =
      for entry <- entries do
        quote do
          @impl PhxLiveStorybook.BackendBehaviour
          def find_entry_by_path(unquote(entry.path)) do
            unquote(Macro.escape(entry))
          end
        end
      end

    single_quote =
      quote do
        def load_story(story_path, opts \\ []) do
          content_path = Keyword.get(unquote(opts), :content_path)
          story_path = String.replace_prefix(story_path, "/", "")
          story_path = story_path <> Entries.story_file_suffix()

          case CodeHelpers.load_exs(story_path, content_path) do
            nil -> nil
            story -> if opts[:validate] == false, do: story, else: StoryValidator.validate!(story)
          end
        end

        @impl PhxLiveStorybook.BackendBehaviour
        def find_entry_by_path(_), do: nil

        @impl PhxLiveStorybook.BackendBehaviour
        def content_tree, do: unquote(Macro.escape(content_tree))

        @impl PhxLiveStorybook.BackendBehaviour
        def leaves, do: unquote(Macro.escape(Entries.leaves(leaves)))

        @impl PhxLiveStorybook.BackendBehaviour
        def flat_list, do: unquote(Macro.escape(entries))
      end

    find_entry_by_path_quotes ++ [single_quote]
  end

  defp content_tree(opts) do
    content_path = Keyword.get(opts, :content_path)
    folders_config = Keyword.get(opts, :folders, [])
    Entries.content_tree(content_path, folders_config)
  end

  @doc false
  defp config_quotes(opts) do
    quote do
      @impl PhxLiveStorybook.BackendBehaviour
      def config(key, default \\ nil) do
        Keyword.get(unquote(opts), key, default)
      end
    end
  end
end
