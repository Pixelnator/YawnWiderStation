/*
 * The shipping request datum object.
 * Should be created one per every inbound or outbound request.
 */

/datum/shipping_request
	var/request_id				// The numeric ID of the request. Note! These can and will overlap!
	var/static/last_rid = 0		// Static to iterate the outbound RID.
	var/origin = "origin"		// The IP of the originating server. "origin" if it's us.
	var/outbound = FALSE		// Showcases whether or not the request is an outbound or an incoming one.
	var/datum/shippingservers/tgt	// For outbound requests, this is the target server's datum.
	var/author_ckey = ""		// Original creator of the request, primarily for logging purposes.
	var/list/items				// List of items to be sent or received. Specific format depends on circumstance.
	var/time_created			// The time at which this request was created.
	var/error_msg = "Unknown error"	// The error message we had appear.

/**
 * Constructor
 *
 * @param	int _rid	The unique ID of the inbound shipping request.
 *						Send null if the request is outbound.
 * @param	str _ckey	The canonincal ckey of the person who made the request.
 * @param	lst _items	If outbound is true, a list of item references to be sent.
 *						If outbound is false, a list of pathnames -> count to be spawned.
 * @param	bool _outbound	True if request is outbound.
 * @param	str _origin	The IP of the orginating server. "origin" if request is outbound.
 *
 * Will raise @exception if insane arguments are sent.
 */
/datum/shipping_request/New(_rid, _ckey, _items, _outbound, _origin, var/datum/shippingservers/_tgt)
	// Sanity check.
	if (!_ckey || !_items)
		throw EXCEPTION("Invalid arguments sent to shipping_request/New().")

	// For days.
	if ((!_outbound && _origin == "origin") || (_outbound && _origin != "origin"))
		throw EXCEPTION("Attempted to create a shipping_request with a bad origin.")

	if (_outbound)
		if (!_tgt || !istype(_tgt))
			throw EXCEPTION("Attempted to create an outbound shipping_request with no target.")
		tgt = _tgt
		request_id = last_rid++
	// Standard only approves of numeric IDs. RIP.
	else if (!isnum(_rid))
		throw EXCEPTION("No request ID sent when creating a new shipping_request.")
	else
		request_id = text2num(_rid)

	// Assignment.
	origin = _origin
	outbound = _outbound
	author_ckey = _ckey

	if (!islist(_items))
		throw EXCEPTION("_items was not a list when creating a new shipping_request.")

	items = _items

	time_created = world.time

/**
 * Deconstructor
 */
/datum/shipping_request/Destroy()
	items = null
	tgt = null
	return ..()

/**
 * @name	outbound_accepted
 *
 * @desc	Only possible for outbound requests.
 *			Will destroy the items from the game world, and mark an outbound request as having been accepted.
 * @return	bool	TRUE if everything goes well.
 *					FALSE if something fails.
 */
/datum/shipping_request/proc/outbound_accepted()
	// Cannot accept an inbound request with this proc.
	if (!outbound)
		error_msg = "outbound_accepted called on an inbound request."
		return FALSE

	// Handle the deletion.
	for (var/item in items)
		if (item)
			qdel(item)

		items -= item

	return TRUE


/**
 * @name	outbound_denied
 *
 * @desc	Only possible for outbound requests.
 *			Will return the items to a reasonable location.
 * @return	bool	TRUE if everything goes well.
 *					FALSE if something fails.
 */
/datum/shipping_request/proc/outbound_denied()
	// Doesn't apply for inbound requests.
	if (!outbound)
		error_msg = "outbound_denied called on an inbound request."
		return FALSE

	// Teleport shit back.
	for (var/obj/I in items)
		if (I)
			I.forceMove(shippping_return)

		items -= I

	return TRUE

/**
 * @name	outbound_send
 *
 * @desc	Only possible for outbound requests.
 *			Will query the destination server with ship_send and attempt
 *			to create a shipping request there. Returns FALSE if the end server
 *			does not accept the query.
 * @return	bool	TRUE if the destination server accepts the request and no errors are encountered.
 *					FALSE if the destination server does not accept the request or an error is encountered.
 */
/datum/shipping_request/proc/outbound_send()
	if (!outbound)
		error_msg = "outbound_send called on an inbound request."
		return FALSE

	var/out_data = json_encode(list("query" = "ship_send", "auth" = config.shipping_auth,
		"ckey" = author_ckey, "rid" = request_id, "items" = get_outbound_items()))
	var/list/data = json_decode(world.Export("byond://[tgt.serverip]?[out_data]"))

	if (!data)
		error_msg = "outbound_send did not receive any data."
		return FALSE

	if (!data["statuscode"] || data["statuscode"] != 200)
		error_msg = "Bad statuscode received. Response: [data["response"]]"
		return FALSE

	shipping_contacts["origin"]["[request_id]"] = src
	return TRUE

/**
 * @name	get_outbound_items
 *
 * @desc	Will go over the atoms in src.items and create a list of ship-id -> count.
 *			For sending away stuff.
 * @return	List of ship-id -> count describing the composition of src.items.
 *			Empty list upon failure.
 */
/datum/shipping_request/proc/get_outbound_items()
	if (!outbound || !items || !items.len)
		return list()

	var/list/data = list()
	for (var/aa in items)
		var/atom/A = aa
		aa = global_shipping_paths["[A.type]"]
		if (!aa)
			continue

		if (!data[aa])
			data[aa] = 1
		else
			data[aa]++

	if (tgt.allowedshipids && tgt.allowedshipids.len)
		for (var/id in data)
			if (!(id in tgt.allowedshipids))
				data -= id

	return data

/**
 * @name	inbound_accepted
 *
 * @desc	Only possible for inbound requests.
 *			Will attempt to spawn the items
 * @return	bool	TRUE if everything goes well.
 *					FALSE if something fails.
 */
/datum/shipping_request/proc/inbound_accepted(var/accepting_ckey)
	if (outbound)
		error_msg = "inbound_accepted called on an outbound request."
		return FALSE

	var/out_data = json_encode(list("query" = "ship_reply", "auth" = config.shipping_auth,
		ckey = accepting_ckey ? accepting_ckey : "server", "accept" = 1, "rid" = request_id))
	var/list/data = json_decode(world.Export("byond://[origin]?[out_data]"))

	if (!data)
		error_msg = "inbound_accepted did not receive any data."
		return FALSE

	if (!data["statuscode"] || data["statuscode"] != 200)
		error_msg = "Bad statuscode received. Response: [data["response"]]"
		return FALSE

	for (var/id in items)
		var/path = text2path(global_shipping_ids[id])
		for (var/i = 0; i < items[id]; i++)
			// Attempt to spawn and move it to the proper place.
			try
				var/obj/I = new path
				I.forceMove(shippping_return)
			catch (var/exception/e)
				error_msg = "Exception while spawning item: [e.desc]"
				return FALSE

	return TRUE

/**
 * @name	inbound_denied
 *
 * @desc	Only possible for inbound requests.
 *			Will discard the request.
 * @return	bool	TRUE if everything goes well.
 *					FALSE if something fails.
 */
/datum/shipping_request/proc/inbound_denied(var/accepting_ckey)
	if (outbound)
		error_msg = "inbound_denied called on an outbound request."
		return FALSE

	var/out_data = json_encode(list("query" = "ship_reply", "auth" = config.shipping_auth, ckey = accepting_ckey ? accepting_ckey : "server", "accept" = 0, "rid" = request_id))
	var/list/data = json_decode(world.Export("byond://[origin]?[out_data]"))

	if (!data)
		error_msg = "inbound_denied did not receive any data."
		return FALSE

	if (!data["statuscode"] || data["statuscode"] != 200)
		error_msg = "Bad statuscode received. Response: [data["response"]]"
		return FALSE

	// This shit may seem empty. But since it's a framework, people may want to handle this differently.
	// So yes, it's a placeholder. items = null is already handled in Destroy(), which should be called after this.
	return TRUE