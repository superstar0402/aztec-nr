use dep::protocol_types::{constants::{MAX_NOTE_HASH_READ_REQUESTS_PER_CALL, GET_NOTES_ORACLE_RETURN_LENGTH}};
use crate::context::PrivateContext;
use crate::note::{
    constants::{GET_NOTE_ORACLE_RETURN_LENGTH, MAX_NOTES_PER_PAGE, VIEW_NOTE_ORACLE_RETURN_LENGTH},
    note_getter_options::{NoteGetterOptions, Select, Sort, SortOrder, Comparator, NoteStatus, PropertySelector},
    note_interface::NoteInterface, note_viewer_options::NoteViewerOptions,
    utils::compute_note_hash_for_read_request
};
use crate::oracle;

fn extract_property_value_from_selector<N>(
    serialized_note: [Field; N],
    selector: PropertySelector
) -> Field {
    // Selectors use PropertySelectors in order to locate note properties inside the serialized note. 
    // This allows easier packing and custom (de)serialization schemas. A note property is located
    // inside the serialized note using the index inside the array, a byte offset and a length.
    let value = serialized_note[selector.index].to_be_bytes(32);
    let offset = selector.offset;
    let length = selector.length;
    let mut value_field = 0 as Field;
    let mut acc: Field = 1;
    for i in 0..32 {
        if i < length {
            value_field += value[31 + offset - i] as Field * acc;
            acc = acc * 256;
        }
    }
    value_field
}

fn check_note_header<Note, N>(
    context: PrivateContext,
    storage_slot: Field,
    note: Note
) where Note: NoteInterface<N> {
    let header = note.get_header();
    let contract_address = context.this_address();
    assert(header.contract_address.eq(contract_address));
    assert(header.storage_slot == storage_slot);
}

fn check_note_fields<N>(serialized_note: [Field; N], selects: BoundedVec<Option<Select>, N>) {
    for i in 0..selects.len {
        let select = selects.get_unchecked(i).unwrap_unchecked();
        let value_field = extract_property_value_from_selector(serialized_note, select.property_selector);

        // Values are computed ahead of time because circuits evaluate all branches
        let is_equal = value_field == select.value.to_field();
        let is_lt = value_field.lt(select.value.to_field());

        if (select.comparator == Comparator.EQ) {
            assert(is_equal, "Mismatch return note field.");
        } else if (select.comparator == Comparator.NEQ) {
            assert(!is_equal, "Mismatch return note field.");
        } else if (select.comparator == Comparator.LT) {
            assert(is_lt, "Mismatch return note field.");
        } else if (select.comparator == Comparator.LTE) {
            assert(is_lt | is_equal, "Mismatch return note field.");
        } else if (select.comparator == Comparator.GT) {
            assert(!is_lt & !is_equal, "Mismatch return note field.");
        } else if (select.comparator == Comparator.GTE) {
            assert(!is_lt, "Mismatch return note field.");
        }
    }
}

fn check_notes_order<N>(
    fields_0: [Field; N],
    fields_1: [Field; N],
    sorts: BoundedVec<Option<Sort>, N>
) {
    for i in 0..sorts.len {
        let sort = sorts.get_unchecked(i).unwrap_unchecked();
        let field_0 = extract_property_value_from_selector(fields_0, sort.property_selector);
        let field_1 = extract_property_value_from_selector(fields_1, sort.property_selector);
        let eq = field_0 == field_1;
        let lt = field_0.lt(field_1);
        if sort.order == SortOrder.ASC {
            assert(eq | lt, "Return notes not sorted in ascending order.");
        } else if !eq {
            assert(!lt, "Return notes not sorted in descending order.");
        }
    }
}

pub fn get_note<Note, N>(
    context: &mut PrivateContext,
    storage_slot: Field
) -> Note where Note: NoteInterface<N> {
    let note = get_note_internal(storage_slot);

    check_note_header(*context, storage_slot, note);

    let note_hash_for_read_request = compute_note_hash_for_read_request(note);

    context.push_note_hash_read_request(note_hash_for_read_request);
    note
}

pub fn get_notes<Note, N, FILTER_ARGS>(
    context: &mut PrivateContext,
    storage_slot: Field,
    options: NoteGetterOptions<Note, N, FILTER_ARGS>
) -> [Option<Note>; MAX_NOTE_HASH_READ_REQUESTS_PER_CALL] where Note: NoteInterface<N> {
    let opt_notes = get_notes_internal(storage_slot, options);

    _get_notes_constrain_get_notes_internal(context, storage_slot, opt_notes, options)
}

pub fn _get_notes_constrain_get_notes_internal<Note, N, FILTER_ARGS>(
    context: &mut PrivateContext,
    storage_slot: Field,
    opt_notes: [Option<Note>; MAX_NOTE_HASH_READ_REQUESTS_PER_CALL],
    options: NoteGetterOptions<Note, N, FILTER_ARGS>
) -> [Option<Note>; MAX_NOTE_HASH_READ_REQUESTS_PER_CALL] where Note: NoteInterface<N> {
    let mut returned_notes = [Option::none(); MAX_NOTE_HASH_READ_REQUESTS_PER_CALL];

    let mut num_notes = 0;
    let mut prev_fields = [0; N];
    for i in 0..opt_notes.len() {
        let opt_note = opt_notes[i];
        if opt_note.is_some() {
            let note = opt_note.unwrap_unchecked();
            let fields = note.serialize_content();
            check_note_header(*context, storage_slot, note);
            check_note_fields(fields, options.selects);
            if i != 0 {
                check_notes_order(prev_fields, fields, options.sorts);
            }
            prev_fields = fields;

            let note_hash_for_read_request = compute_note_hash_for_read_request(note);
            // TODO(https://github.com/AztecProtocol/aztec-packages/issues/1410): test to ensure
            // failure if malicious oracle injects 0 nonce here for a "pre-existing" note.
            context.push_note_hash_read_request(note_hash_for_read_request);

            // The below code is used to collapse a sparse array into one where the values are guaranteed to be at the front of the array
            // We write at returned_notes[num_notes] because num_notes is only advanced when we have a value in opt_notes
            returned_notes[num_notes] = Option::some(note);
            num_notes += 1;
        };
    }
    if options.limit != 0 {
        assert(num_notes <= options.limit, "Invalid number of return notes.");
    }

    assert(num_notes != 0, "Cannot return zero notes");

    returned_notes
}

unconstrained fn get_note_internal<Note, N>(storage_slot: Field) -> Note where Note: NoteInterface<N> {
    let placeholder_note = [Option::none()];
    let placeholder_fields = [0; GET_NOTE_ORACLE_RETURN_LENGTH];
    let placeholder_note_length = [0; N];
    oracle::notes::get_notes(
        storage_slot,
        0,
        [],
        [],
        [],
        [],
        [],
        [],
        [],
        [],
        [],
        1, // limit
        0, // offset
        NoteStatus.ACTIVE,
        placeholder_note,
        placeholder_fields,
        placeholder_note_length
    )[0].unwrap() // Notice: we don't allow dummies to be returned from get_note (singular).
}

unconstrained fn get_notes_internal<Note, N, FILTER_ARGS>(
    storage_slot: Field,
    options: NoteGetterOptions<Note, N, FILTER_ARGS>
) -> [Option<Note>; MAX_NOTE_HASH_READ_REQUESTS_PER_CALL] where Note: NoteInterface<N> {
    let (num_selects, select_by_indexes, select_by_offsets, select_by_lengths, select_values, select_comparators, sort_by_indexes, sort_by_offsets, sort_by_lengths, sort_order) = flatten_options(options.selects, options.sorts);
    let placeholder_opt_notes = [Option::none(); MAX_NOTE_HASH_READ_REQUESTS_PER_CALL];
    let placeholder_fields = [0; GET_NOTES_ORACLE_RETURN_LENGTH];
    let placeholder_note_length = [0; N];
    let opt_notes = oracle::notes::get_notes(
        storage_slot,
        num_selects,
        select_by_indexes,
        select_by_offsets,
        select_by_lengths,
        select_values,
        select_comparators,
        sort_by_indexes,
        sort_by_offsets,
        sort_by_lengths,
        sort_order,
        options.limit,
        options.offset,
        options.status,
        placeholder_opt_notes,
        placeholder_fields,
        placeholder_note_length
    );

    let filter = options.filter;
    let filter_args = options.filter_args;
    filter(opt_notes, filter_args)
}

unconstrained pub fn view_notes<Note, N>(
    storage_slot: Field,
    options: NoteViewerOptions<Note, N>
) -> [Option<Note>; MAX_NOTES_PER_PAGE] where Note: NoteInterface<N> {
    let (num_selects, select_by_indexes, select_by_offsets, select_by_lengths, select_values, select_comparators, sort_by_indexes, sort_by_offsets, sort_by_lengths, sort_order) = flatten_options(options.selects, options.sorts);
    let placeholder_opt_notes = [Option::none(); MAX_NOTES_PER_PAGE];
    let placeholder_fields = [0; VIEW_NOTE_ORACLE_RETURN_LENGTH];
    let placeholder_note_length = [0; N];
    oracle::notes::get_notes(
        storage_slot,
        num_selects,
        select_by_indexes,
        select_by_offsets,
        select_by_lengths,
        select_values,
        select_comparators,
        sort_by_indexes,
        sort_by_offsets,
        sort_by_lengths,
        sort_order,
        options.limit,
        options.offset,
        options.status,
        placeholder_opt_notes,
        placeholder_fields,
        placeholder_note_length
    )
}

unconstrained fn flatten_options<Note, N>(
    selects: BoundedVec<Option<Select>, N>,
    sorts: BoundedVec<Option<Sort>, N>
) -> (u8, [u8; N], [u8; N], [u8; N], [Field; N], [u8; N], [u8; N], [u8; N], [u8; N], [u8; N]) {
    let mut num_selects = 0;
    let mut select_by_indexes = [0; N];
    let mut select_by_offsets = [0; N];
    let mut select_by_lengths = [0; N];
    let mut select_values = [0; N];
    let mut select_comparators = [0; N];

    for i in 0..selects.len {
        let select = selects.get(i);
        if select.is_some() {
            select_by_indexes[num_selects] = select.unwrap_unchecked().property_selector.index;
            select_by_offsets[num_selects] = select.unwrap_unchecked().property_selector.offset;
            select_by_lengths[num_selects] = select.unwrap_unchecked().property_selector.length;
            select_values[num_selects] = select.unwrap_unchecked().value;
            select_comparators[num_selects] = select.unwrap_unchecked().comparator;
            num_selects += 1;
        };
    }

    let mut sort_by_indexes = [0; N];
    let mut sort_by_offsets = [0; N];
    let mut sort_by_lengths = [0; N];
    let mut sort_order = [0; N];
    for i in 0..sorts.len {
        let sort = sorts.get(i);
        if sort.is_some() {
            sort_by_indexes[i] = sort.unwrap_unchecked().property_selector.index;
            sort_by_offsets[i] = sort.unwrap_unchecked().property_selector.offset;
            sort_by_lengths[i] = sort.unwrap_unchecked().property_selector.length;
            sort_order[i] = sort.unwrap_unchecked().order;
        };
    }

    (
        num_selects, select_by_indexes, select_by_offsets, select_by_lengths, select_values, select_comparators, sort_by_indexes, sort_by_offsets, sort_by_lengths, sort_order
    )
}
