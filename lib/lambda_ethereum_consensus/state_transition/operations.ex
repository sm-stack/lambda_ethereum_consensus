defmodule LambdaEthereumConsensus.StateTransition.Operations do
  @moduledoc """
  This module contains functions for handling state transition
  """

  alias LambdaEthereumConsensus.StateTransition.Accessors
  alias LambdaEthereumConsensus.StateTransition.Misc
  alias LambdaEthereumConsensus.StateTransition.Mutators
  alias LambdaEthereumConsensus.StateTransition.Predicates
  alias SszTypes.BeaconState
  alias SszTypes.Attestation
  alias SszTypes

  @doc """
  Process total slashing balances updates during epoch processing
  """
  @spec process_attestation(BeaconState.t(), Attestation.t()) ::
          {:ok, BeaconState.t()} | {:error, binary()}
  def process_attestation(state, attestation) do
    case verify_attestation_for_process(state, attestation) do
      {:ok, _} ->
        data = attestation.data
        aggregation_bits = attestation.aggregation_bits
        case process_attestation(state, data, aggregation_bits) do
          {:ok, updated_state} -> {:ok, updated_state}
          {:error, reason} -> {:error, reason}
        end
      {:error, reason} -> {:error, reason}
    end
  end

  defp process_attestation(state, data, aggregation_bits) do
    # Participation flag indices
    with {:ok, participation_flag_indices} <- Accessors.get_attestation_participation_flag_indices(
        state,
        data,
        state.slot - data.slot),
        {:ok, attesting_indices} <- Accessors.get_attesting_indices(state, data, aggregation_bits)
       do

      # Update epoch participation flags
      is_current_epoch = data.target.epoch == Accessors.get_current_epoch(state)
      initial_epoch_participation =
        if is_current_epoch do
          state.current_epoch_participation
        else
          state.previous_epoch_participation
        end

      # attesting_indices =
      #   Accessors.get_attesting_indices(state, data, aggregation_bits)

      {proposer_reward_numerator, updated_epoch_participation} =
        Enum.reduce(attesting_indices, {0, initial_epoch_participation}, fn index, {acc, ep} ->
          {new_acc, new_ep} =
            Enum.reduce_while(
              0..(length(Constants.participation_flag_weights()) - 1),
              {acc, ep},
              fn flag_index, {inner_acc, inner_ep} ->
                if flag_index in participation_flag_indices &&
                    not Predicates.has_flag(Enum.at(inner_ep, index), flag_index) do
                  updated_ep =
                    List.replace_at(
                      inner_ep,
                      index,
                      Misc.add_flag(Enum.at(inner_ep, index), flag_index)
                    )
                  acc_delta =
                    Accessors.get_base_reward(state, index) *
                    Enum.at(Constants.participation_flag_weights(), flag_index)
                  {:cont, {inner_acc + acc_delta, updated_ep}}
                else
                  {:cont, {inner_acc, inner_ep}}
                end
              end
            )

          {new_acc, new_ep}
        end)

      # Reward proposer
      proposer_reward_denominator =
        ((Constants.weight_denominator() - Constants.proposer_weight()) *
            Constants.weight_denominator())
        |> div(Constants.proposer_weight())

      proposer_reward = div(proposer_reward_numerator, proposer_reward_denominator)

      {:ok, bal_updated_state} =
        Mutators.increase_balance(
          state,
          Accessors.get_beacon_proposer_index(state),
          proposer_reward
        )

      updated_state =
        if is_current_epoch do
          %{bal_updated_state | current_epoch_participation: updated_epoch_participation}
        else
          %{bal_updated_state | previous_epoch_participation: updated_epoch_participation}
        end

      {:ok, updated_state}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def verify_attestation_for_process(state, attestation) do
    data = attestation.data
    beacon_committee =
      case Accessors.get_beacon_committee(state, data.slot, data.index) do
        {:ok, committee} -> committee
        {:error, _reason} -> nil
      end
    indexed_attestation =
      case Accessors.get_indexed_attestation(state, attestation) do
        {:ok, indexed_attestation} -> indexed_attestation
        {:error, _reason} -> nil
      end

    result =
      cond do
        data.target.epoch < Accessors.get_previous_epoch(state) ||
        data.target.epoch > Accessors.get_current_epoch(state) ->
          {:error, "Incorrect target epoch"}
        data.target.epoch != Misc.compute_epoch_at_slot(data.slot) ->
          {:error, "Epoch mismatch"}
        state.slot < data.slot + ChainSpec.get("MIN_ATTESTATION_INCLUSION_DELAY") ||
        state.slot > data.slot + ChainSpec.get("SLOTS_PER_EPOCH") ->
          {:error, "Inclusion delay not met"}
        data.index >= Accessors.get_committee_count_per_slot(state, data.target.epoch) ->
          {:error, "Index exceeds committee count"}
        !beacon_committee || !indexed_attestation ->
          {:error, "Indexing error at beacon committee"}
        # SSZ formatted bitlist has extra 1 bit at the end
        length_of_bitstring(attestation.aggregation_bits) - 1 !=
        length(beacon_committee) ->
          {:error, "Mismatched aggregation bits length"}
        # Verify signature
        Predicates.is_valid_indexed_attestation(state, indexed_attestation) != {:ok, true} ->
          {:error, "Invalid signature"}
        true ->
          {:ok, "Valid"}
      end
    result
  end

  defp length_of_bitstring(binary) when is_binary(binary) do
    binary
    |> :binary.bin_to_list()
    |> Enum.reduce("", fn byte, acc ->
      acc <> Integer.to_string(byte, 2)
    end)
    |> String.length()
  end
end
