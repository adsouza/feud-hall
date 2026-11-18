defmodule FeudHall.Domain.BusinessName do
  @moduledoc "Display name bounds shared by restaurants and stalls."

  def valid?(value),
    do: is_binary(value) and byte_size(value) in 1..160 and String.length(value) in 1..40 and String.printable?(value)
end
