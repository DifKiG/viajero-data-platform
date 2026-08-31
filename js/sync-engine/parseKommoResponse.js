/**
 * VIAJERO DATA PLATFORM
 * SYNC ENGINE
 */

function parseKommoResponse(raw) {

    if (!raw) {
        throw new Error("La respuesta está vacía.");
    }

    if (!raw.data) {
        throw new Error("La propiedad data no existe.");
    }

    const body = JSON.parse(raw.data);

    return {
        page: body._page || 1,
        next: body._links?.next?.href || null,
        hasNext: Boolean(body._links?.next?.href),
        totalItems: body._embedded?.leads?.length || 0,
        items: body._embedded?.leads || []
    };
}

module.exports = parseKommoResponse;