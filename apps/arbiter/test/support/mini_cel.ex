defmodule Arbiter.Test.MiniCel do
  @moduledoc """
  A small interpreter for the subset of CEL the Arbiter `ValidatingAdmissionPolicy`
  uses (`docs/design/remote-workers.md` §7), so the policy's expressions can be
  evaluated **verbatim** against built pods without a cluster (K4).

  Supported: field selection, `has(a.b.c)`, `==`, `!=`, `&&`, `||`, `!`, `+`
  (lists and strings), `cond ? a : b`, string / boolean / integer / list
  literals, `list.all(v, expr)`, `string.startsWith(prefix)`, and a
  `variables.<name>` environment. Anything else is a parse error, never a silent
  pass.

  Semantics that matter for admission: selecting a field that is absent is an
  **error**, and an expression that errors is a **denial** (`failurePolicy:
  Fail`). `&&` and `||` absorb an error when the other operand decides the
  result (`false && error` is `false`, `true || error` is `true`), exactly as CEL
  does; `.all` is `false` if any element is `false`, an error if none is false
  but one errored. `has()` evaluates the parent selection (so a missing parent
  is an error) and tests the last key.

  The API server hands CEL the object converted from its typed form, where a
  plain `bool` field that is `false` is omitted (`hostNetwork`, `hostPID`,
  `hostIPC`); a pointer field (`hostUsers`, `automountServiceAccountToken`) keeps
  its `false`. The builder never emits the plain-bool fields at all, so the
  difference does not matter to its pods; negative controls that set one set it
  to `true`.

  This is a test tool, not the engine: the spike (K1) ran the same expressions on
  a real API server (`docs/design/k8s-spike/results/k1-design-vap-cel-verbatim.txt`).
  """

  @type result :: {:ok, term()} | {:error, String.t()}

  @doc "Evaluate `source` with `bindings` (`%{\"object\" => pod, \"variables\" => %{...}}`)."
  @spec eval(String.t(), map()) :: result()
  def eval(source, bindings) do
    with {:ok, tokens} <- tokenize(source, []),
         {:ok, ast, []} <- parse_ternary(tokens) do
      run(ast, bindings)
    else
      {:ok, _ast, rest} -> {:error, "trailing tokens: #{inspect(Enum.take(rest, 3))}"}
      {:error, _} = error -> error
    end
  end

  @doc "Whether the policy admits: only a plain `true` does; `false` and an error both deny."
  @spec admits?(String.t(), map()) :: boolean()
  def admits?(source, bindings), do: eval(source, bindings) == {:ok, true}

  # -- tokens -------------------------------------------------------------------------------------

  defp tokenize("", acc), do: {:ok, Enum.reverse(acc)}
  defp tokenize(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\n, ?\r], do: tokenize(rest, acc)

  defp tokenize(<<"'", rest::binary>>, acc) do
    case String.split(rest, "'", parts: 2) do
      [str, rest] -> tokenize(rest, [{:str, str} | acc])
      _ -> {:error, "unterminated string"}
    end
  end

  defp tokenize(<<op::binary-size(2), rest::binary>>, acc) when op in ["&&", "||", "==", "!="],
    do: tokenize(rest, [{:op, op} | acc])

  defp tokenize(<<c, rest::binary>>, acc) when c in ~c"!()[],.?:+",
    do: tokenize(rest, [{:op, <<c>>} | acc])

  defp tokenize(<<c, _::binary>> = input, acc) when c in ?0..?9 do
    {digits, rest} = take_while(input, &(&1 in ?0..?9))
    tokenize(rest, [{:int, String.to_integer(digits)} | acc])
  end

  defp tokenize(<<c, _::binary>> = input, acc) when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {ident, rest} = take_while(input, &(&1 in ?a..?z or &1 in ?A..?Z or &1 in ?0..?9 or &1 == ?_))
    tokenize(rest, [{:id, ident} | acc])
  end

  defp tokenize(<<c, _::binary>>, _acc), do: {:error, "unexpected character #{<<c>>}"}

  defp take_while(bin, fun), do: take_while(bin, fun, "")

  defp take_while(<<c, rest::binary>>, fun, acc) do
    if fun.(c), do: take_while(rest, fun, acc <> <<c>>), else: {acc, <<c, rest::binary>>}
  end

  defp take_while("", _fun, acc), do: {acc, ""}

  # -- parser (precedence: ?: < || < && < == != < + < ! < postfix) ----------------------------------------------

  defp parse_ternary(tokens) do
    with {:ok, cond, rest} <- parse_or(tokens) do
      case rest do
        [{:op, "?"} | rest] ->
          with {:ok, a, [{:op, ":"} | rest]} <- parse_ternary(rest),
               {:ok, b, rest} <- parse_ternary(rest),
               do: {:ok, {:if, cond, a, b}, rest}

        _ ->
          {:ok, cond, rest}
      end
    end
  end

  defp parse_or(tokens), do: binary(tokens, &parse_and/1, ["||"], :or)
  defp parse_and(tokens), do: binary(tokens, &parse_eq/1, ["&&"], :and)
  defp parse_eq(tokens), do: binary(tokens, &parse_add/1, ["==", "!="], :cmp)
  defp parse_add(tokens), do: binary(tokens, &parse_unary/1, ["+"], :add)

  defp binary(tokens, next, ops, tag) do
    with {:ok, left, rest} <- next.(tokens), do: binary_loop(left, rest, next, ops, tag)
  end

  defp binary_loop(left, [{:op, op} | rest], next, ops, tag) do
    if op in ops do
      with {:ok, right, rest} <- next.(rest) do
        node = if tag in [:cmp], do: {tag, op, left, right}, else: {tag, left, right}
        binary_loop(node, rest, next, ops, tag)
      end
    else
      {:ok, left, [{:op, op} | rest]}
    end
  end

  defp binary_loop(left, rest, _next, _ops, _tag), do: {:ok, left, rest}

  defp parse_unary([{:op, "!"} | rest]) do
    with {:ok, expr, rest} <- parse_unary(rest), do: {:ok, {:not, expr}, rest}
  end

  defp parse_unary(tokens), do: parse_postfix(tokens)

  defp parse_postfix(tokens) do
    with {:ok, primary, rest} <- parse_primary(tokens), do: postfix(primary, rest)
  end

  defp postfix(node, [{:op, "."}, {:id, name}, {:op, "("} | rest]) do
    with {:ok, args, rest} <- parse_args(rest, []), do: postfix({:call, node, name, args}, rest)
  end

  defp postfix(node, [{:op, "."}, {:id, name} | rest]), do: postfix({:select, node, name}, rest)
  defp postfix(node, rest), do: {:ok, node, rest}

  defp parse_args([{:op, ")"} | rest], acc), do: {:ok, Enum.reverse(acc), rest}

  defp parse_args([{:op, ","} | rest], acc), do: parse_args(rest, acc)

  defp parse_args([{:id, name}, {:op, ","} | rest], acc) when acc == [] do
    # macro form `all(v, expr)`: the first argument is a binder, not an expression
    case parse_ternary(rest) do
      {:ok, body, [{:op, ")"} | rest]} -> {:ok, [{:binder, name}, body], rest}
      {:ok, _, other} -> {:error, "bad macro arguments near #{inspect(Enum.take(other, 2))}"}
      error -> error
    end
  end

  defp parse_args(tokens, acc) do
    with {:ok, arg, rest} <- parse_ternary(tokens), do: parse_args(rest, [arg | acc])
  end

  defp parse_primary([{:str, s} | rest]), do: {:ok, {:lit, s}, rest}
  defp parse_primary([{:int, n} | rest]), do: {:ok, {:lit, n}, rest}
  defp parse_primary([{:id, "true"} | rest]), do: {:ok, {:lit, true}, rest}
  defp parse_primary([{:id, "false"} | rest]), do: {:ok, {:lit, false}, rest}

  defp parse_primary([{:id, "has"}, {:op, "("} | rest]) do
    with {:ok, expr, [{:op, ")"} | rest]} <- parse_ternary(rest) do
      case expr do
        {:select, parent, key} -> {:ok, {:has, parent, key}, rest}
        _ -> {:error, "has() needs a field selection"}
      end
    end
  end

  defp parse_primary([{:id, name} | rest]), do: {:ok, {:var, name}, rest}

  defp parse_primary([{:op, "("} | rest]) do
    with {:ok, expr, [{:op, ")"} | rest]} <- parse_ternary(rest), do: {:ok, expr, rest}
  end

  defp parse_primary([{:op, "["} | rest]), do: parse_list(rest, [])
  defp parse_primary(other), do: {:error, "unexpected #{inspect(Enum.take(other, 2))}"}

  defp parse_list([{:op, "]"} | rest], acc), do: {:ok, {:list, Enum.reverse(acc)}, rest}
  defp parse_list([{:op, ","} | rest], acc), do: parse_list(rest, acc)

  defp parse_list(tokens, acc) do
    with {:ok, item, rest} <- parse_ternary(tokens), do: parse_list(rest, [item | acc])
  end

  # -- evaluation ------------------------------------------------------------------------------------------------

  defp run({:lit, v}, _env), do: {:ok, v}

  defp run({:var, name}, env) do
    case Map.fetch(env, name) do
      {:ok, v} -> {:ok, v}
      :error -> {:error, "undeclared reference to '#{name}'"}
    end
  end

  defp run({:list, items}, env) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case run(item, env) do
        {:ok, v} -> {:cont, {:ok, acc ++ [v]}}
        error -> {:halt, error}
      end
    end)
  end

  defp run({:select, node, key}, env) do
    with {:ok, value} <- run(node, env), do: select(value, key)
  end

  defp run({:has, parent, key}, env) do
    with {:ok, value} <- run(parent, env) do
      case value do
        %{} -> {:ok, Map.has_key?(value, key)}
        _ -> {:error, "has() on a non-object"}
      end
    end
  end

  defp run({:not, node}, env) do
    case run(node, env) do
      {:ok, v} when is_boolean(v) -> {:ok, not v}
      {:ok, _} -> {:error, "! needs a bool"}
      error -> error
    end
  end

  defp run({:and, a, b}, env), do: logic(run(a, env), run(b, env), false)
  defp run({:or, a, b}, env), do: logic(run(a, env), run(b, env), true)

  defp run({:cmp, op, a, b}, env) do
    with {:ok, x} <- run(a, env), {:ok, y} <- run(b, env) do
      {:ok, if(op == "==", do: x == y, else: x != y)}
    end
  end

  defp run({:add, a, b}, env) do
    with {:ok, x} <- run(a, env), {:ok, y} <- run(b, env) do
      cond do
        is_list(x) and is_list(y) -> {:ok, x ++ y}
        is_binary(x) and is_binary(y) -> {:ok, x <> y}
        true -> {:error, "no such overload for +"}
      end
    end
  end

  defp run({:if, c, a, b}, env) do
    case run(c, env) do
      {:ok, true} -> run(a, env)
      {:ok, false} -> run(b, env)
      {:ok, _} -> {:error, "?: needs a bool"}
      error -> error
    end
  end

  defp run({:call, recv, "startsWith", [arg]}, env) do
    with {:ok, s} <- run(recv, env), {:ok, p} <- run(arg, env) do
      if is_binary(s) and is_binary(p),
        do: {:ok, String.starts_with?(s, p)},
        else: {:error, "startsWith needs strings"}
    end
  end

  defp run({:call, recv, "all", [{:binder, var}, body]}, env) do
    with {:ok, list} <- run(recv, env) do
      if is_list(list), do: all(list, var, body, env), else: {:error, "all() on a non-list"}
    end
  end

  defp run({:call, _recv, name, _args}, _env), do: {:error, "unsupported function #{name}"}

  defp select(%{} = map, key) do
    case Map.fetch(map, key) do
      {:ok, v} -> {:ok, v}
      :error -> {:error, "no such key: #{key}"}
    end
  end

  defp select(_other, key), do: {:error, "cannot select #{key} on a non-object"}

  defp logic({:ok, d}, _other, d) when is_boolean(d), do: {:ok, d}
  defp logic(_other, {:ok, d}, d) when is_boolean(d), do: {:ok, d}
  defp logic({:error, _} = e, _, _), do: e
  defp logic(_, {:error, _} = e, _), do: e
  defp logic({:ok, a}, {:ok, b}, _) when is_boolean(a) and is_boolean(b), do: {:ok, a}
  defp logic(_, _, _), do: {:error, "logical operator needs bools"}

  defp all(list, var, body, env) do
    results = Enum.map(list, &run(body, Map.put(env, var, &1)))

    cond do
      Enum.any?(results, &(&1 == {:ok, false})) -> {:ok, false}
      error = Enum.find(results, &match?({:error, _}, &1)) -> error
      Enum.all?(results, &(&1 == {:ok, true})) -> {:ok, true}
      true -> {:error, "all() needs bools"}
    end
  end
end
